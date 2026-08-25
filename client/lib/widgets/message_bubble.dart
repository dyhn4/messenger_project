import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/app_user.dart';
import '../models/message.dart';
import '../models/room.dart';
import '../screens/chat_screen.dart';
import '../screens/home_screen.dart' show wideBreakpoint;
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
  final bool showTime;
  final bool showSenderInfo;
  final bool highlighted; // 검색 결과에서 열었을 때 잠깐 노란색으로 표시(chat_panel.dart 참고).

  const MessageBubble({
    super.key,
    required this.session,
    required this.message,
    required this.resolveUrl,
    this.unreadCount = 0,
    this.isMine = false,
    this.sender,
    this.showTime = true,
    this.showSenderInfo = true,
    this.highlighted = false,
  });

  Future<void> _openProfile(BuildContext context) async {
    if (isMine) {
      showDialog(context: context, builder: (_) => MyProfileDialog(session: session));
      return;
    }
    if (sender != null) {
      // MemberProfileDialog에서 "1:1 메시지"를 누르면 새로 만들어진/기존 DM 방을 반환한다 —
      // 넓은(PC) 화면은 옆 패널만 바꾸고, 좁은(모바일) 화면은 전체화면으로 그 방을 띄운다.
      final room = await showDialog<Room>(
        context: context,
        builder: (_) => MemberProfileDialog(session: session, user: sender!),
      );
      if (room == null || !context.mounted) return;
      if (MediaQuery.sizeOf(context).width >= wideBreakpoint) {
        session.requestOpenRoom(room);
      } else {
        Navigator.of(context).push(MaterialPageRoute(builder: (_) => ChatScreen(session: session, room: room)));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // 이름이 바뀌었을 수도 있으니, 메시지에 박제된 senderName보다 지금 알고 있는 이름을
    // 우선한다(나는 session.name, 남은 room.members에서 찾은 sender.name).
    final displayName = (isMine ? session.name : sender?.name) ?? message.senderName;
    const avatarDiameter = 32.0;
    const contentIndent = avatarDiameter + 8; // 아바타 너비 + 아바타-내용 간격.

    final bubbleRow = Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeOut,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: highlighted
                  ? const Color(0xFFFFF59D)
                  : (isMine
                      ? Theme.of(context).colorScheme.primaryContainer
                      : Theme.of(context).colorScheme.surfaceContainerHighest),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 이미지/파일에 캡션(같이 입력한 메시지)이 붙어 있으면 그 위에 먼저 보여준다.
                if (message.type != MessageType.text && (message.text?.isNotEmpty ?? false)) ...[
                  SelectableText(message.text!),
                  const SizedBox(height: 6),
                ],
                _buildContent(context),
              ],
            ),
          ),
        ),
        if (unreadCount > 0) ...[
          const SizedBox(width: 4),
          Text(
            '$unreadCount',
            style: TextStyle(color: Colors.orange.shade800, fontWeight: FontWeight.bold, fontSize: 11),
          ),
        ],
        if (showTime) ...[
          const SizedBox(width: 6),
          Text(
            _timeFormat.format(message.createdAt),
            style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).hintColor),
          ),
        ],
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 같은 사람이 연달아 보낸 메시지는 첫 메시지에만 프로필 사진/이름을 보여준다.
          // 이름은 아바타와 한 줄에서 세로 중앙에 오도록 정렬하고, 말풍선은 그 아래
          // (아바타 하단 높이만큼 들여쓴 채) 별도 줄로 둔다.
          if (showSenderInfo) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _openProfile(context),
                    child: AvatarView(
                      username: displayName,
                      avatarType: sender?.avatarType ?? 'initial',
                      avatarEmoji: sender?.avatarEmoji,
                      avatarColor: sender?.avatarColor,
                      avatarUrl: sender?.avatarUrl,
                      resolveUrl: resolveUrl,
                      radius: avatarDiameter / 2,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => _openProfile(context),
                    child: Text(displayName, style: const TextStyle(fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
          ],
          Padding(
            padding: const EdgeInsets.only(left: contentIndent),
            child: bubbleRow,
          ),
        ],
      ),
    );
  }

  Widget _buildContent(BuildContext context) {
    switch (message.type) {
      case MessageType.image:
        final url = resolveUrl(message.fileUrl ?? '');
        return _DownloadableImage(session: session, url: url, fileName: message.fileName ?? 'image.png');
      case MessageType.file:
        final url = resolveUrl(message.fileUrl ?? '');
        return _DownloadableFile(session: session, url: url, fileName: message.fileName ?? '파일');
      case MessageType.text:
        return SelectableText(message.text ?? '');
      case MessageType.system:
        // ChatPanel이 system 메시지는 SystemMessageRow로 따로 그려서 이 위젯까지 안 옴.
        return const SizedBox.shrink();
    }
  }
}

/// 첨부 하나를 다운로드해서 저장한다. 환경설정에서 "저장 위치 안 물어보기"가 켜져 있으면
/// 설정된 폴더에 바로 저장하고, 꺼져 있으면 저장 위치를 물어본다. 저장 후 "다운로드 완료 시
/// 폴더 열기"가 켜져 있으면 그 폴더를 연다. 저장된 경로를 반환한다(취소되면 null).
Future<String?> _saveAttachment({required Session session, required String url, required String fileName}) async {
  final res = await http.get(Uri.parse(url));
  if (res.statusCode >= 400) throw Exception('다운로드에 실패했습니다.');

  final settings = session.settings;
  String? savedPath;
  if (settings.downloadWithoutAsking && settings.downloadFolder.isNotEmpty) {
    final path = '${settings.downloadFolder}${Platform.pathSeparator}$fileName';
    await File(path).writeAsBytes(res.bodyBytes);
    savedPath = path;
  } else {
    savedPath = await FilePicker.saveFile(
      fileName: fileName,
      initialDirectory: settings.downloadFolder.isEmpty ? null : settings.downloadFolder,
      bytes: res.bodyBytes,
    );
  }

  if (savedPath != null && settings.openFolderAfterDownload) {
    await settings.openDownloadFolder();
  }
  return savedPath;
}

/// 마우스를 올렸을 때만 보이는 원형 다운로드 버튼. 이미지/파일 첨부 위젯이 공유해서 쓴다.
class _DownloadOverlayButton extends StatelessWidget {
  final bool downloading;
  final VoidCallback onTap;
  const _DownloadOverlayButton({required this.downloading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.55),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: downloading ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: downloading
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Icon(Icons.download, size: 16, color: Colors.white),
        ),
      ),
    );
  }
}

/// 채팅에 올라온 이미지 하나. 누르면 크게 보고, 마우스를 올리면 오른쪽 위에 다운로드 버튼이 뜬다.
class _DownloadableImage extends StatefulWidget {
  final Session session;
  final String url;
  final String fileName;
  const _DownloadableImage({required this.session, required this.url, required this.fileName});

  @override
  State<_DownloadableImage> createState() => _DownloadableImageState();
}

class _DownloadableImageState extends State<_DownloadableImage> {
  bool _hovering = false;
  bool _downloading = false;

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final savedPath = await _saveAttachment(session: widget.session, url: widget.url, fileName: widget.fileName);
      if (!mounted) return;
      if (savedPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('다운로드 완료: $savedPath')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('다운로드 실패: $e')));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => ImageViewerScreen(imageUrl: widget.url)),
        ),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedNetworkImage(
                imageUrl: widget.url,
                width: 200,
                fit: BoxFit.cover,
                placeholder: (context, _) =>
                    const SizedBox(width: 200, height: 150, child: Center(child: CircularProgressIndicator())),
                errorWidget: (context, _, error) =>
                    const SizedBox(width: 200, height: 150, child: Icon(Icons.broken_image)),
              ),
            ),
            if (_hovering)
              Positioned(
                right: 6,
                top: 6,
                child: _DownloadOverlayButton(downloading: _downloading, onTap: _download),
              ),
          ],
        ),
      ),
    );
  }
}

/// 채팅에 올라온 파일 하나. 누르면 외부 앱으로 열고, 마우스를 올리면 오른쪽 위에 다운로드 버튼이 뜬다.
class _DownloadableFile extends StatefulWidget {
  final Session session;
  final String url;
  final String fileName;
  const _DownloadableFile({required this.session, required this.url, required this.fileName});

  @override
  State<_DownloadableFile> createState() => _DownloadableFileState();
}

class _DownloadableFileState extends State<_DownloadableFile> {
  bool _hovering = false;
  bool _downloading = false;

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final savedPath = await _saveAttachment(session: widget.session, url: widget.url, fileName: widget.fileName);
      if (!mounted) return;
      if (savedPath != null) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('다운로드 완료: $savedPath')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('다운로드 실패: $e')));
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: () => launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              constraints: const BoxConstraints(maxWidth: 220),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                border: Border.all(color: Theme.of(context).dividerColor),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.insert_drive_file_outlined),
                  const SizedBox(width: 8),
                  Flexible(child: Text(widget.fileName, overflow: TextOverflow.ellipsis)),
                ],
              ),
            ),
            if (_hovering)
              Positioned(
                right: -6,
                top: -6,
                child: _DownloadOverlayButton(downloading: _downloading, onTap: _download),
              ),
          ],
        ),
      ),
    );
  }
}
