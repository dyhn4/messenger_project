import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../screens/image_viewer_screen.dart';
import '../services/session.dart';

/// 첨부 하나를 다운로드해서 저장한다. 환경설정에서 "저장 위치 안 물어보기"가 켜져 있으면
/// 설정된 폴더에 바로 저장하고, 꺼져 있으면 저장 위치를 물어본다. 저장 후 "다운로드 완료 시
/// 폴더 열기"가 켜져 있으면 그 폴더를 연다. 저장된 경로를 반환한다(취소되면 null).
/// MessageBubble의 이미지/파일 첨부와 댓글의 이미지/파일 첨부가 같이 쓴다.
Future<String?> saveAttachment({
  required Session session,
  required String url,
  required String fileName,
}) async {
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
      initialDirectory: settings.downloadFolder.isEmpty
          ? null
          : settings.downloadFolder,
      bytes: res.bodyBytes,
    );
  }

  if (savedPath != null && settings.openFolderAfterDownload) {
    await settings.openDownloadFolder();
  }
  return savedPath;
}

/// 마우스를 올렸을 때만 보이는 원형 다운로드 버튼. 이미지/파일 첨부 위젯이 공유해서 쓴다.
class DownloadOverlayButton extends StatelessWidget {
  final bool downloading;
  final VoidCallback onTap;
  const DownloadOverlayButton({
    super.key,
    required this.downloading,
    required this.onTap,
  });

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
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.download, size: 16, color: Colors.white),
        ),
      ),
    );
  }
}

/// 채팅/댓글에 올라온 이미지 하나. 누르면 크게 보고, 마우스를 올리면 오른쪽 위에 다운로드 버튼이 뜬다.
class DownloadableImage extends StatefulWidget {
  final Session session;
  final String url;
  final String fileName;
  const DownloadableImage({
    super.key,
    required this.session,
    required this.url,
    required this.fileName,
  });

  @override
  State<DownloadableImage> createState() => _DownloadableImageState();
}

class _DownloadableImageState extends State<DownloadableImage> {
  bool _hovering = false;
  bool _downloading = false;

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final savedPath = await saveAttachment(
        session: widget.session,
        url: widget.url,
        fileName: widget.fileName,
      );
      if (!mounted) return;
      if (savedPath != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('다운로드 완료: $savedPath')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('다운로드 실패: $e')));
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
          MaterialPageRoute(
            builder: (_) => ImageViewerScreen(imageUrl: widget.url),
          ),
        ),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: CachedNetworkImage(
                imageUrl: widget.url,
                width: 200,
                // placeholder/errorWidget과 높이를 맞춰서(150) 고정한다 — 안 그러면 이미지가
                // 원본 비율대로 로드되면서 크기가 바뀌어, 로드되기 전 크기를 기준으로 계산해둔
                // 스크롤 위치(맨 아래로 스크롤 등)가 로드 후 어긋나는 문제가 있었다.
                height: 150,
                fit: BoxFit.cover,
                placeholder: (context, _) => const SizedBox(
                  width: 200,
                  height: 150,
                  child: Center(child: CircularProgressIndicator()),
                ),
                errorWidget: (context, _, error) => const SizedBox(
                  width: 200,
                  height: 150,
                  child: Icon(Icons.broken_image),
                ),
              ),
            ),
            if (_hovering)
              Positioned(
                right: 6,
                top: 6,
                child: DownloadOverlayButton(
                  downloading: _downloading,
                  onTap: _download,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 채팅/댓글에 올라온 파일 하나. 누르면 외부 앱으로 열고, 마우스를 올리면 오른쪽 위에 다운로드 버튼이 뜬다.
class DownloadableFile extends StatefulWidget {
  final Session session;
  final String url;
  final String fileName;
  const DownloadableFile({
    super.key,
    required this.session,
    required this.url,
    required this.fileName,
  });

  @override
  State<DownloadableFile> createState() => _DownloadableFileState();
}

class _DownloadableFileState extends State<DownloadableFile> {
  bool _hovering = false;
  bool _downloading = false;

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final savedPath = await saveAttachment(
        session: widget.session,
        url: widget.url,
        fileName: widget.fileName,
      );
      if (!mounted) return;
      if (savedPath != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('다운로드 완료: $savedPath')));
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('다운로드 실패: $e')));
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
        onTap: () => launchUrl(
          Uri.parse(widget.url),
          mode: LaunchMode.externalApplication,
        ),
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
                  Flexible(
                    child: Text(
                      widget.fileName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            if (_hovering)
              Positioned(
                right: -6,
                top: -6,
                child: DownloadOverlayButton(
                  downloading: _downloading,
                  onTap: _download,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
