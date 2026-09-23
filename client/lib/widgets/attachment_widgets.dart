import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/message.dart' show Message, MessageAttachment;
import '../models/room.dart';
import '../screens/image_viewer_screen.dart';
import '../screens/pdf_viewer_screen.dart';
import '../screens/text_viewer_screen.dart';
import '../services/secret_chat_crypto.dart' as secret_crypto;
import '../services/session.dart';
import 'file_actions.dart';

/// 파일명을 눌렀을 때 메신저 창 안에서 바로 열어 보여줄 수 있는 확장자인지 — 그 외(워드/엑셀/
/// 파워포인트 등)는 지금처럼 OS 기본 프로그램으로 연다. Flutter 생태계에 오피스 문서를 원본
/// 서식 그대로 렌더링하는 방법이 마땅치 않아서(서버에 LibreOffice 변환 파이프라인을 새로
/// 두지 않는 한), 인앱 뷰어는 부담 없이 구현 가능한 PDF/텍스트로 한정한다.
bool _isInAppViewable(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  return ext == 'pdf' || ext == 'txt';
}

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
/// 버블에는 (있으면) 축소 썸네일을 보여주고, 실제로 열거나 다운로드할 때만 원본을 가져온다 —
/// 그래야 썸네일을 따로 만든 보람이 있다(매번 원본을 미리 받아두면 의미가 없음).
class DownloadableImage extends StatefulWidget {
  final Session session;
  final String url; // 원본.
  final String fileName;

  /// 비밀 대화의 원본에만 채워진다 — 있으면 [url]이 가리키는 건 암호화된 바이트라는 뜻.
  final String? attachmentKey;
  final String? attachmentNonce;

  /// 채팅 버블 미리보기용 축소 썸네일 경로. null이면(예전 메시지, 또는 썸네일 생성 실패) 원본을
  /// 그대로 미리보기에 쓴다.
  final String? thumbnailUrl;
  final String? thumbnailKey;
  final String? thumbnailNonce;

  const DownloadableImage({
    super.key,
    required this.session,
    required this.url,
    required this.fileName,
    this.attachmentKey,
    this.attachmentNonce,
    this.thumbnailUrl,
    this.thumbnailKey,
    this.thumbnailNonce,
  });

  @override
  State<DownloadableImage> createState() => _DownloadableImageState();
}

class _DownloadableImageState extends State<DownloadableImage> {
  bool _hovering = false;
  bool _downloading = false;
  Future<Uint8List>? _previewBytes;

  bool get _hasThumbnail => widget.thumbnailUrl != null;
  String get _previewUrl => widget.thumbnailUrl ?? widget.url;
  String? get _previewKey =>
      _hasThumbnail ? widget.thumbnailKey : widget.attachmentKey;
  String? get _previewNonce =>
      _hasThumbnail ? widget.thumbnailNonce : widget.attachmentNonce;
  bool get _previewIsSecret => _previewKey != null;

  @override
  void initState() {
    super.initState();
    if (_previewIsSecret) {
      _previewBytes = fetchAttachmentBytes(
        url: _previewUrl,
        attachmentKey: _previewKey,
        attachmentNonce: _previewNonce,
      );
    }
  }

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

  void _open() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen.single(
          imageUrl: widget.url,
          // 원본이 암호화돼 있으면(비밀 대화) 여는 시점에 새로 다운로드+복호화한다 — 미리보기는
          // 이미 축소 썸네일로 봤으니 굳이 미리 받아둘 필요가 없다.
          imageBytesFuture: widget.attachmentKey != null
              ? fetchAttachmentBytes(
                  url: widget.url,
                  attachmentKey: widget.attachmentKey,
                  attachmentNonce: widget.attachmentNonce,
                )
              : null,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final image = _previewIsSecret
        ? FutureBuilder<Uint8List>(
            future: _previewBytes,
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
            imageUrl: _previewUrl,
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
        onTap: _open,
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

/// 채팅 버블 안 이미지 미리보기의 기본 가로 크기. 창이 좁으면 그만큼 줄어든다.
const kChatImageMaxWidth = 650.0;

/// 미리보기 한 칸의 최대 세로 — 열이 적을수록(=칸이 클수록) 더 낮게 잘라서, 사진 한 장이
/// 대화창을 다 먹지 않게 한다. 열 수를 키로 쓴다(1열 / 2열 / 3열).
const kChatImageMaxHeights = {1: 200.0, 2: 300.0, 3: 420.0};

double chatImageMaxHeight(int columns) =>
    kChatImageMaxHeights[columns] ?? kChatImageMaxHeights[3]!;

/// 격자 한 줄에 놓는 장수(사진 3장마다 줄바꿈).
const kChatImageGridColumns = 3;

/// 한 메시지에 딸린 이미지들을 채팅 버블에 그린다. 한 장이면 가로 [kChatImageMaxWidth]에
/// 맞춰 크게(세로는 원본 비율대로, 너무 길면 잘라서), 여러 장이면 3열 격자로 보여준다.
/// 아무 장이나 누르면 뷰어가 열리고 거기서 좌우로 넘길 수 있다.
class ChatImageAttachments extends StatelessWidget {
  final Session session;
  final List<MessageAttachment> attachments;

  /// "더보기"(파일 전달·다운로드·즐겨찾기·원본 보기)와 뷰어 상단 바에 필요하다.
  /// 안 주면 그 메뉴와 상단 바 버튼은 안 나온다(파일 모아보기 화면 등).
  final Message? message;
  final Room? room;

  /// 비밀 대화 첨부의 복호화 키 — 지금은 한 장짜리(예전 방식)에만 채워진다.
  final String? attachmentKey;
  final String? attachmentNonce;
  final String? thumbnailKey;
  final String? thumbnailNonce;

  const ChatImageAttachments({
    super.key,
    required this.session,
    required this.attachments,
    this.message,
    this.room,
    this.attachmentKey,
    this.attachmentNonce,
    this.thumbnailKey,
    this.thumbnailNonce,
  });

  /// 뷰어에 넘길 목록 — 비밀 대화면 여는 시점에 원본을 받아 복호화한다.
  List<ViewerImage> _viewerImages() => [
    for (final a in attachments)
      ViewerImage(
        url: session.resolveUrl(a.fileUrl),
        fileName: a.fileName ?? 'image.png',
        fileSize: a.fileSize,
        bytesFuture: attachmentKey == null
            ? null
            : fetchAttachmentBytes(
                url: session.resolveUrl(a.fileUrl),
                attachmentKey: attachmentKey,
                attachmentNonce: attachmentNonce,
              ),
      ),
  ];

  void _open(BuildContext context, int index) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(
          images: _viewerImages(),
          initialIndex: index,
          session: session,
          message: message,
          room: room,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        // 창을 좁히면 미리보기도 같이 줄어든다(maxWidth가 무한이면 기본값을 쓴다).
        final width = constraints.hasBoundedWidth
            ? math.min(kChatImageMaxWidth, constraints.maxWidth)
            : kChatImageMaxWidth;
        if (attachments.length == 1) {
          return _ChatImageTile(
            session: session,
            message: message,
            attachment: attachments.first,
            width: width,
            maxHeight: chatImageMaxHeight(1),
            attachmentKey: attachmentKey,
            attachmentNonce: attachmentNonce,
            thumbnailKey: thumbnailKey,
            thumbnailNonce: thumbnailNonce,
            onTap: () => _open(context, 0),
          );
        }
        const gap = 4.0;
        final columns = math.min(kChatImageGridColumns, attachments.length);
        final cell = (width - gap * (columns - 1)) / columns;
        return SizedBox(
          width: width,
          child: Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (var i = 0; i < attachments.length; i++)
                _ChatImageTile(
                  session: session,
                  message: message,
                  attachment: attachments[i],
                  width: cell,
                  // 격자는 칸 크기를 맞춰야 줄이 가지런하다 — 정사각형으로 자르되,
                  // 열 수에 따른 최대 높이를 넘지 않게 한다.
                  fixedHeight: math.min(cell, chatImageMaxHeight(columns)),
                  onTap: () => _open(context, i),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 미리보기 한 칸. [fixedHeight]를 주면 그 높이로 잘라 보여주고(격자), 안 주면 원본 비율대로
/// 그리되 [maxHeight]를 넘지 않게 한다(한 장짜리).
class _ChatImageTile extends StatefulWidget {
  final Session session;
  final Message? message;
  final MessageAttachment attachment;
  final double width;
  final double? fixedHeight;
  final double maxHeight;
  final String? attachmentKey;
  final String? attachmentNonce;
  final String? thumbnailKey;
  final String? thumbnailNonce;
  final VoidCallback onTap;

  const _ChatImageTile({
    required this.session,
    required this.attachment,
    this.message,
    required this.width,
    required this.onTap,
    this.fixedHeight,
    this.maxHeight = 420,
    this.attachmentKey,
    this.attachmentNonce,
    this.thumbnailKey,
    this.thumbnailNonce,
  });

  @override
  State<_ChatImageTile> createState() => _ChatImageTileState();
}

class _ChatImageTileState extends State<_ChatImageTile> {
  bool _hovering = false;
  bool _downloading = false;
  Future<Uint8List>? _previewBytes;

  /// 원본 가로/세로 비 — 알아내면 그 비율로 높이를 잡는다(알기 전에는 아래 기본값).
  double? _ratio;
  ImageStream? _stream;
  ImageStreamListener? _listener;

  bool get _hasThumbnail => widget.attachment.thumbnailUrl != null;
  String get _previewUrl => widget.session.resolveUrl(
    widget.attachment.thumbnailUrl ?? widget.attachment.fileUrl,
  );
  String? get _previewKey =>
      _hasThumbnail ? widget.thumbnailKey : widget.attachmentKey;
  String? get _previewNonce =>
      _hasThumbnail ? widget.thumbnailNonce : widget.attachmentNonce;
  bool get _previewIsSecret => _previewKey != null;

  @override
  void initState() {
    super.initState();
    if (_previewIsSecret) {
      _previewBytes = fetchAttachmentBytes(
        url: _previewUrl,
        attachmentKey: _previewKey,
        attachmentNonce: _previewNonce,
      );
    } else if (widget.fixedHeight == null) {
      _listenForRatio();
    }
  }

  /// 한 장짜리는 세로를 원본 비율대로 잡아야 해서, 미리 크기만 알아본다(그리기 전에 한 번).
  void _listenForRatio() {
    final stream = CachedNetworkImageProvider(
      _previewUrl,
    ).resolve(const ImageConfiguration());
    final listener = ImageStreamListener((info, _) {
      if (!mounted) return;
      final ratio = info.image.width / info.image.height;
      if (ratio.isFinite && ratio > 0) setState(() => _ratio = ratio);
    }, onError: (_, _) {});
    stream.addListener(listener);
    _stream = stream;
    _listener = listener;
  }

  @override
  void dispose() {
    if (_stream != null && _listener != null) {
      _stream!.removeListener(_listener!);
    }
    super.dispose();
  }

  /// 더보기 메뉴가 쓰는 동작 묶음 — 메시지를 모르면(파일 모아보기 등) 만들지 않는다.
  FileActions? _actions() {
    final message = widget.message;
    if (message == null) return null;
    return FileActions(
      session: widget.session,
      message: message,
      url: widget.session.resolveUrl(widget.attachment.fileUrl),
      fileName: widget.attachment.fileName ?? 'image.png',
      attachmentKey: widget.attachmentKey,
      attachmentNonce: widget.attachmentNonce,
    );
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final savedPath = await saveAttachment(
        session: widget.session,
        url: widget.session.resolveUrl(widget.attachment.fileUrl),
        fileName: widget.attachment.fileName ?? 'image.png',
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

  @override
  Widget build(BuildContext context) {
    final width = widget.width;
    // 비율을 아직 모르면 가로:세로 = 3:2쯤으로 자리를 잡아둔다 — 알게 되면 그 비율로 바뀐다.
    final height =
        widget.fixedHeight ??
        math.min(widget.maxHeight, width / (_ratio ?? 1.5));

    final Widget image = _previewIsSecret
        ? FutureBuilder<Uint8List>(
            future: _previewBytes,
            builder: (context, snapshot) {
              if (snapshot.hasError) {
                return SizedBox(
                  width: width,
                  height: height,
                  child: const Icon(Icons.broken_image),
                );
              }
              if (!snapshot.hasData) {
                return SizedBox(
                  width: width,
                  height: height,
                  child: const Center(child: CircularProgressIndicator()),
                );
              }
              return Image.memory(
                snapshot.data!,
                width: width,
                height: height,
                fit: BoxFit.cover,
              );
            },
          )
        : CachedNetworkImage(
            imageUrl: _previewUrl,
            width: width,
            height: height,
            fit: BoxFit.cover,
            placeholder: (context, _) => SizedBox(
              width: width,
              height: height,
              child: const Center(child: CircularProgressIndicator()),
            ),
            errorWidget: (context, _, error) => SizedBox(
              width: width,
              height: height,
              child: const Icon(Icons.broken_image),
            ),
          );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Stack(
          children: [
            ClipRRect(borderRadius: BorderRadius.circular(10), child: image),
            if (_hovering)
              Positioned(
                right: 6,
                top: 6,
                child: Row(
                  children: [
                    DownloadOverlayButton(
                      downloading: _downloading,
                      onTap: _download,
                    ),
                    if (widget.message != null) ...[
                      const SizedBox(width: 4),
                      _MoreMenuButton(actions: _actions()!),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 썸네일 오른쪽 위의 "더보기" — 파일 전달 · 다운로드 · 즐겨찾기 · 원본 파일 보기.
class _MoreMenuButton extends StatelessWidget {
  final FileActions actions;
  const _MoreMenuButton({required this.actions});

  @override
  Widget build(BuildContext context) {
    return MenuAnchor(
      menuChildren: [
        SizedBox(
          width: 200,
          child: MenuItemButton(
            leadingIcon: const Icon(Icons.send_outlined, size: 18),
            onPressed: () => actions.forward(context),
            child: const Text('파일 전달'),
          ),
        ),
        SizedBox(
          width: 200,
          child: MenuItemButton(
            leadingIcon: const Icon(Icons.download_outlined, size: 18),
            onPressed: () => actions.download(context),
            child: const Text('다운로드'),
          ),
        ),
        SizedBox(
          width: 200,
          child: MenuItemButton(
            leadingIcon: const Icon(Icons.star_border, size: 18),
            onPressed: () => actions.toggleFavorite(context),
            child: const Text('즐겨찾기'),
          ),
        ),
        SizedBox(
          width: 200,
          child: MenuItemButton(
            leadingIcon: const Icon(Icons.image_outlined, size: 18),
            onPressed: () => actions.openOriginal(context),
            child: const Text('원본 파일 보기'),
          ),
        ),
      ],
      builder: (context, controller, _) => Material(
        color: Colors.black45,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () =>
              controller.isOpen ? controller.close() : controller.open(),
          child: const Padding(
            padding: EdgeInsets.all(6),
            child: Icon(Icons.more_horiz, size: 16, color: Colors.white),
          ),
        ),
      ),
    );
  }
}

/// 채팅/댓글에 올라온 파일 하나. 누르면 항상 먼저 전체를 다 받은 뒤에 PDF/텍스트는 인앱
/// 뷰어로, 그 외는 외부 앱으로 열고(_open 참고), 마우스를 올리면 오른쪽 위에 다운로드
/// 버튼이 뜬다.
class DownloadableFile extends StatefulWidget {
  final Session session;
  final String url;
  final String fileName;

  /// DownloadableImage와 동일한 의미 — 있으면 서버 URL은 암호화된 바이트라, 복호화해야
  /// 실제 내용을 볼 수 있다.
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

  /// 파일명을 누르면 항상 먼저 전체를 다 받은 뒤에(비밀 대화면 복호화까지) 연다 — 비밀
  /// 대화가 아닌 파일도 서버 URL을 그대로 OS에 던지면 브라우저가 형식에 따라 바로 열거나
  /// 자기 다운로드 폴더에 받아버리는 등 동작이 제각각이라, 항상 이 앱이 직접 받아서 연 다음
  /// 순서를 보장한다(비밀 대화 파일이 원래 하던 방식과 동일하게 통일).
  Future<void> _open() async {
    setState(() => _opening = true);
    try {
      final bytes = await fetchAttachmentBytes(
        url: widget.url,
        attachmentKey: widget.attachmentKey,
        attachmentNonce: widget.attachmentNonce,
      );
      if (!mounted) return;

      if (_isInAppViewable(widget.fileName)) {
        final ext = widget.fileName.split('.').last.toLowerCase();
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ext == 'pdf'
                ? PdfViewerScreen(
                    fileName: widget.fileName,
                    bytesFuture: Future.value(bytes),
                  )
                : TextViewerScreen(
                    fileName: widget.fileName,
                    bytesFuture: Future.value(bytes),
                  ),
          ),
        );
        return;
      }

      // 비밀 대화 파일은 계속 임시 폴더에만 받는다 — 복호화된 평문을 사용자의 영구 다운로드
      // 폴더에 남기지 않기 위한 의도적인 구분이다. 일반 파일은 설정에서 다운로드 폴더를
      // 지정해뒀으면 그 폴더에 실제로 저장해서 열고(다운로드 버튼으로 받은 것과 같은 파일이
      // 다운로드 폴더에 남아있게), 지정 안 했으면 원래대로 임시 폴더로 폴백한다.
      final isSecret = widget.attachmentKey != null;
      final downloadFolder = widget.session.settings.downloadFolder;
      final dirPath = (!isSecret && downloadFolder.isNotEmpty)
          ? downloadFolder
          : (await getTemporaryDirectory()).path;
      final file = File('$dirPath${Platform.pathSeparator}${widget.fileName}');
      await file.writeAsBytes(bytes);
      await launchUrl(
        Uri.file(file.path),
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
        onTap: _opening ? null : _open,
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

/// "42.3MB" 같은 사람이 읽기 좋은 용량 표기.
String formatFileSize(int bytes) {
  if (bytes < 1024) return '${bytes}B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(1)}KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(1)}MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(1)}GB';
}

/// 첨부를 서버에 올리는 동안 채팅/댓글 목록에 보여주는 자리표시자. DownloadableImage/
/// DownloadableFile의 "업로드 버전" — Message/Comment를 직접 받지 않고 순수 값만 받아서,
/// 채팅 메시지와 댓글 양쪽에서 그대로 재사용한다. 진행률은 호출부(RoomChatController)가
/// 원본 객체의 필드를 갱신하고 notifyListeners()를 부르면, 이 위젯이 새 값으로 다시 그려진다.
class UploadingAttachment extends StatelessWidget {
  final Uint8List? thumbnailBytes;
  final String displayName;
  final int totalBytes;
  final int sentBytes;

  /// 업로드가 끝났으면 true — 썸네일/카드 모양은 그대로 두고 진행바+퍼센트만 없애서 용량만
  /// 보여준다(업로드 중 → 완료 전환 때 카드 자체가 다른 위젯으로 바뀌지 않게 하기 위함 —
  /// 예전엔 완료되면 작은 칩으로 통째로 바뀌어서 썸네일이 "달라 보인다"는 피드백이 있었다).
  final bool completed;
  final VoidCallback onCancel;
  const UploadingAttachment({
    super.key,
    required this.thumbnailBytes,
    required this.displayName,
    required this.totalBytes,
    required this.sentBytes,
    required this.completed,
    required this.onCancel,
  });

  double? get _progress => totalBytes > 0 ? sentBytes / totalBytes : null;

  /// 이미지 썸네일(64x64, 정사각형) 위에 얹는 반투명 스크림 — 폭이 좁아서 용량+막대+퍼센트를
  /// 한 줄에 다 넣을 자리가 없다. 업로드 중엔 퍼센트만 작게 보여주고 그 아래 얇은 진행바를
  /// 폭 전체에 깔며, 끝나면 진행바 없이 용량만 보여준다(완료 후에도 값은 남아있게).
  Widget _buildImageOverlay(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(4),
      ),
      child: completed
          ? Text(
              formatFileSize(totalBytes),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 9),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _progress != null ? '${(_progress! * 100).round()}%' : '',
                  style: const TextStyle(color: Colors.white, fontSize: 9),
                ),
                const SizedBox(height: 2),
                LinearProgressIndicator(
                  value: _progress,
                  minHeight: 3,
                  backgroundColor: Colors.white24,
                  valueColor: const AlwaysStoppedAnimation(Colors.white),
                ),
              ],
            ),
    );
  }

  /// 파일 카드(가로형) 안의 용량 줄 — 업로드 중엔 진행바+퍼센트, 끝나면 용량 텍스트만.
  Widget _buildFileProgressRow(BuildContext context) {
    final hintColor = Theme.of(context).hintColor;
    if (completed) {
      return Text(
        formatFileSize(totalBytes),
        style: TextStyle(fontSize: 11, color: hintColor),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          formatFileSize(totalBytes),
          style: TextStyle(fontSize: 11, color: hintColor),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 60,
          child: LinearProgressIndicator(
            value: _progress,
            minHeight: 4,
            backgroundColor: Theme.of(context).dividerColor,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          _progress != null ? '${(_progress! * 100).round()}%' : '',
          style: TextStyle(fontSize: 11, color: hintColor),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final cancelButton = Positioned(
      top: -6,
      right: -6,
      child: GestureDetector(
        onTap: onCancel,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.close, size: 12, color: Colors.white),
        ),
      ),
    );

    if (thumbnailBytes != null) {
      // 이미지 — 64x64 정사각형 썸네일(파일 카드와 높이를 맞춤), 하단에 용량(+업로드
      // 중이면 진행바/퍼센트) 오버레이.
      return Stack(
        clipBehavior: Clip.none,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              children: [
                Image.memory(
                  thumbnailBytes!,
                  width: 64,
                  height: 64,
                  fit: BoxFit.cover,
                ),
                Positioned(
                  left: 3,
                  right: 3,
                  bottom: 3,
                  child: _buildImageOverlay(context),
                ),
              ],
            ),
          ),
          cancelButton,
        ],
      );
    }

    // 파일 — DownloadableFile(실제 전송된 파일 말풍선)과 같은 가로형 카드: 아이콘 왼쪽 +
    // 파일명 오른쪽, 그 아래 용량/진행률.
    return Stack(
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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.insert_drive_file_outlined,
                    color: Theme.of(context).hintColor,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(displayName, overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              _buildFileProgressRow(context),
            ],
          ),
        ),
        cancelButton,
      ],
    );
  }
}

/// 파일 탐색기에서 채팅방/댓글 패널 위로 파일을 끌고 왔을 때(아직 놓기 전) 보여주는 전체
/// 오버레이 — "여기에 놓으면 된다"를 명확하게 보여준다. chat_panel.dart/message_thread_screen.dart가
/// DropTarget의 hovering 상태일 때 패널 전체를 덮어 그린다(Windows 전용, desktop_drop 기반).
class DropZoneOverlay extends StatelessWidget {
  const DropZoneOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      color: scheme.surface.withValues(alpha: 0.92),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 96,
            height: 96,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: 0.12),
            ),
            child: Icon(
              Icons.upload_file_outlined,
              size: 44,
              color: scheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            '파일을 이곳에 드래그 & 드롭하여 업로드하세요',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
