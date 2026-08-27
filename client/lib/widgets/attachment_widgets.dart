import 'dart:io';
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../screens/image_viewer_screen.dart';
import '../services/secret_chat_crypto.dart' as secret_crypto;
import '../services/session.dart';

/// 첨부를 내려받아 [attachmentKey]/[attachmentNonce]가 있으면(비밀 대화) 그 자리에서 복호화까지
/// 한다 — 서버는 암호화된 바이트만 갖고 있으므로 표시/저장 전에 항상 이 함수를 거쳐야 한다.
Future<Uint8List> fetchAttachmentBytes({
  required String url,
  String? attachmentKey,
  String? attachmentNonce,
}) async {
  final res = await http.get(Uri.parse(url));
  if (res.statusCode >= 400) throw Exception('다운로드에 실패했습니다.');
  if (attachmentKey == null || attachmentNonce == null) return res.bodyBytes;

  final plain = await secret_crypto.decryptAttachment(
    cipherBytes: res.bodyBytes,
    keyBase64: attachmentKey,
    nonceBase64: attachmentNonce,
  );
  if (plain == null) throw Exception('첨부를 복호화할 수 없습니다.');
  return plain;
}

/// 첨부 하나를 다운로드해서 저장한다. 환경설정에서 "저장 위치 안 물어보기"가 켜져 있으면
/// 설정된 폴더에 바로 저장하고, 꺼져 있으면 저장 위치를 물어본다. 저장 후 "다운로드 완료 시
/// 폴더 열기"가 켜져 있으면 그 폴더를 연다. 저장된 경로를 반환한다(취소되면 null).
/// MessageBubble의 이미지/파일 첨부와 댓글의 이미지/파일 첨부가 같이 쓴다.
Future<String?> saveAttachment({
  required Session session,
  required String url,
  required String fileName,
  String? attachmentKey,
  String? attachmentNonce,
}) async {
  final bytes = await fetchAttachmentBytes(
    url: url,
    attachmentKey: attachmentKey,
    attachmentNonce: attachmentNonce,
  );

  final settings = session.settings;
  String? savedPath;
  if (settings.downloadWithoutAsking && settings.downloadFolder.isNotEmpty) {
    final path = '${settings.downloadFolder}${Platform.pathSeparator}$fileName';
    await File(path).writeAsBytes(bytes);
    savedPath = path;
  } else {
    savedPath = await FilePicker.saveFile(
      fileName: fileName,
      initialDirectory: settings.downloadFolder.isEmpty
          ? null
          : settings.downloadFolder,
      bytes: bytes,
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

  /// 비밀 대화의 이미지만 채워진다 — 있으면 서버가 갖고 있는 건 암호화된 바이트라는 뜻이라
  /// 캐시 네트워크 이미지 대신 다운로드+복호화 후 메모리 이미지로 보여준다.
  final String? attachmentKey;
  final String? attachmentNonce;
  const DownloadableImage({
    super.key,
    required this.session,
    required this.url,
    required this.fileName,
    this.attachmentKey,
    this.attachmentNonce,
  });

  @override
  State<DownloadableImage> createState() => _DownloadableImageState();
}

class _DownloadableImageState extends State<DownloadableImage> {
  bool _hovering = false;
  bool _downloading = false;
  Future<Uint8List>? _decryptedBytes;

  bool get _isSecret => widget.attachmentKey != null;

  @override
  void initState() {
    super.initState();
    if (_isSecret) _decryptedBytes = _fetch();
  }

  Future<Uint8List> _fetch() => fetchAttachmentBytes(
    url: widget.url,
    attachmentKey: widget.attachmentKey,
    attachmentNonce: widget.attachmentNonce,
  );

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final savedPath = await saveAttachment(
        session: widget.session,
        url: widget.url,
        fileName: widget.fileName,
        attachmentKey: widget.attachmentKey,
        attachmentNonce: widget.attachmentNonce,
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

  Future<void> _open(Uint8List? bytes) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ImageViewerScreen(imageUrl: widget.url, imageBytes: bytes),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _isSecret
        ? FutureBuilder<Uint8List>(
            future: _decryptedBytes,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return const SizedBox(
                  width: 200,
                  height: 150,
                  child: Icon(Icons.broken_image),
                );
              }
              if (!snapshot.hasData) {
                return const SizedBox(
                  width: 200,
                  height: 150,
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              return Image.memory(
                snapshot.data!,
                width: 200,
                height: 150,
                fit: BoxFit.cover,
              );
            },
          )
        : CachedNetworkImage(
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
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: _isSecret
            ? () async => _open(await _decryptedBytes)
            : () => _open(null),
        child: Stack(
          children: [
            ClipRRect(borderRadius: BorderRadius.circular(10), child: image),
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

  /// DownloadableImage와 동일한 의미 — 있으면 서버 URL은 암호화된 바이트라 바로 열 수 없고,
  /// 다운로드+복호화 후 임시 파일로 저장해야 외부 앱으로 열 수 있다.
  final String? attachmentKey;
  final String? attachmentNonce;
  const DownloadableFile({
    super.key,
    required this.session,
    required this.url,
    required this.fileName,
    this.attachmentKey,
    this.attachmentNonce,
  });

  @override
  State<DownloadableFile> createState() => _DownloadableFileState();
}

class _DownloadableFileState extends State<DownloadableFile> {
  bool _hovering = false;
  bool _downloading = false;
  bool _opening = false;

  bool get _isSecret => widget.attachmentKey != null;

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final savedPath = await saveAttachment(
        session: widget.session,
        url: widget.url,
        fileName: widget.fileName,
        attachmentKey: widget.attachmentKey,
        attachmentNonce: widget.attachmentNonce,
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

  /// 비밀 대화 첨부는 서버 URL이 암호화된 바이트라 그 URL을 그대로 외부 앱으로 열 수 없다 —
  /// 복호화한 뒤 임시 파일에 써서 그 로컬 경로를 연다.
  Future<void> _openSecret() async {
    setState(() => _opening = true);
    try {
      final bytes = await fetchAttachmentBytes(
        url: widget.url,
        attachmentKey: widget.attachmentKey,
        attachmentNonce: widget.attachmentNonce,
      );
      final dir = await getTemporaryDirectory();
      final tempFile = File('${dir.path}/${widget.fileName}');
      await tempFile.writeAsBytes(bytes);
      await launchUrl(
        Uri.file(tempFile.path),
        mode: LaunchMode.externalApplication,
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('열기 실패: $e')));
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: _isSecret
            ? (_opening ? null : _openSecret)
            : () => launchUrl(
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
