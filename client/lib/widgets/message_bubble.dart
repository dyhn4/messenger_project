import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../screens/image_viewer_screen.dart';
import '../screens/member_profile_dialog.dart';
import '../screens/my_profile_dialog.dart';
import '../services/session.dart';
import 'avatar_utils.dart';

final _timeFormat = DateFormat('a h:mm');

/// 메시지 한 줄: 아바타 + 보낸사람 이름 + (말풍선 + 시간). 항상 좌측 정렬이지만
/// 내가 보낸 메시지는 말풍선 색을 다르게 해서 구분한다. 아바타/이름을 누르면 내 메시지는
/// 내 프로필 카드, 다른 사람 메시지는 그 사람의 프로필 카드가 뜬다.
class MessageBubble extends StatelessWidget {
  final Session session;
  final Message message;
  final String Function(String relative) resolveUrl;
  final int unreadCount;
  final bool isMine;
  final AppUser? sender;

  const MessageBubble({
    super.key,
    required this.session,
    required this.message,
    required this.resolveUrl,
    this.unreadCount = 0,
    this.isMine = false,
    this.sender,
  });

  void _openProfile(BuildContext context) {
    if (isMine) {
      showDialog(context: context, builder: (_) => MyProfileDialog(session: session));
    } else if (sender != null) {
      showDialog(context: context, builder: (_) => MemberProfileDialog(session: session, user: sender!));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => _openProfile(context),
              child: AvatarView(
                username: message.senderName,
                avatarType: sender?.avatarType ?? 'initial',
                avatarEmoji: sender?.avatarEmoji,
                avatarColor: sender?.avatarColor,
                avatarUrl: sender?.avatarUrl,
                resolveUrl: resolveUrl,
                radius: 16,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _openProfile(context),
                    child: Text(message.senderName, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(height: 2),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: isMine
                              ? Theme.of(context).colorScheme.primaryContainer
                              : Theme.of(context).colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: _buildContent(context),
                      ),
                    ),
                    if (unreadCount > 0) ...[
                      const SizedBox(width: 4),
                      Text(
                        '$unreadCount',
                        style: TextStyle(color: Colors.orange.shade800, fontWeight: FontWeight.bold, fontSize: 11),
                      ),
                    ],
                    const SizedBox(width: 6),
                    Text(
                      _timeFormat.format(message.createdAt),
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).hintColor),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (message.type) {
      case MessageType.image:
        final url = resolveUrl(message.fileUrl ?? '');
        return GestureDetector(
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => ImageViewerScreen(imageUrl: url)),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: CachedNetworkImage(
              imageUrl: url,
              width: 200,
              fit: BoxFit.cover,
              placeholder: (context, _) =>
                  const SizedBox(width: 200, height: 150, child: Center(child: CircularProgressIndicator())),
              errorWidget: (context, _, error) =>
                  const SizedBox(width: 200, height: 150, child: Icon(Icons.broken_image)),
            ),
          ),
        );
      case MessageType.file:
        return InkWell(
          onTap: () => launchUrl(Uri.parse(resolveUrl(message.fileUrl ?? '')), mode: LaunchMode.externalApplication),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.insert_drive_file_outlined),
              const SizedBox(width: 8),
              Flexible(child: Text(message.fileName ?? '파일', overflow: TextOverflow.ellipsis)),
            ],
          ),
        );
      case MessageType.text:
        return SelectableText(message.text ?? '');
      case MessageType.system:
        // ChatPanel이 system 메시지는 SystemMessageRow로 따로 그려서 이 위젯까지 안 옴.
        return const SizedBox.shrink();
    }
  }
}
