import 'dart:math' as math;
import 'dart:typed_data';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/message.dart' show Message, MessageAttachment, MessageType;
import '../models/room.dart';
import '../screens/image_viewer_screen.dart';
import '../screens/pdf_viewer_screen.dart';
import '../screens/text_viewer_screen.dart';
import '../services/clipboard_image.dart' show canCopyImageToClipboard;
import '../services/download_storage.dart';
import '../services/secret_chat_crypto.dart' as secret_crypto;
import '../services/session.dart';
import 'app_toast.dart';
import 'data_usage_warning.dart';
import 'deleted_file_card.dart';
import 'file_actions.dart';
import 'hover_toolbar.dart';

/// 파일명을 눌렀을 때 메신저 창 안에서 바로 열어 보여줄 수 있는 확장자인지 — 그 외(워드/엑셀/
/// 파워포인트 등)는 지금처럼 OS 기본 프로그램으로 연다. Flutter 생태계에 오피스 문서를 원본
/// 서식 그대로 렌더링하는 방법이 마땅치 않아서(서버에 LibreOffice 변환 파이프라인을 새로
/// 두지 않는 한), 인앱 뷰어는 부담 없이 구현 가능한 PDF/텍스트로 한정한다.
bool _isInAppViewable(String fileName) {
  final ext = fileName.split('.').last.toLowerCase();
  // 웹은 PDF를 브라우저 자체 뷰어(새 탭)로 연다 — 앱의 PDF 뷰어(pdfx)는 웹에서 pdf.js를 따로 받아 와야 해서.
  return (ext == 'pdf' && !kIsWeb) || ext == 'txt';
}

/// 첨부를 내려받아 [attachmentKey]/[attachmentNonce]가 있으면(비밀 대화) 그 자리에서 복호화까지
/// 한다 — 서버는 암호화된 바이트만 갖고 있으므로 표시/저장 전에 항상 이 함수를 거쳐야 한다.
///
/// 메시지에 실려 온 링크는 최대 2시간 뒤에 만료돼서(서버 signFileUrl) 앱을 오래 켜 둔 채 받으면
/// 401이 난다. [session]을 주면 그때 서버에서 새 링크를 받아 한 번 더 시도한다.
Future<Uint8List> fetchAttachmentBytes({
  required String url,
  String? attachmentKey,
  String? attachmentNonce,
  Session? session,
}) async {
  var res = await http.get(Uri.parse(url));
  final api = session?.api;
  if (res.statusCode == 401 && api != null) {
    try {
      final fresh = await api.resignFileUrl(Uri.parse(url).path);
      res = await http.get(Uri.parse(session!.resolveUrl(fresh)));
    } catch (_) {
      // 새 링크를 못 받으면 아래에서 처음 응답 그대로 실패로 처리한다.
    }
  }
  if (res.statusCode >= 400) {
    throw Exception('다운로드에 실패했습니다. (HTTP ${res.statusCode})');
  }
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
/// 설정된 폴더에 바로 저장하고(안드로이드는 늘 Download/TangoTalk에 바로 — 같은 이름이 있으면
/// 덮어쓰지 않고 번호를 붙인다), 꺼져 있으면 저장 위치를 물어본다. 저장 후 "다운로드 완료 시
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
    session: session,
    url: url,
    attachmentKey: attachmentKey,
    attachmentNonce: attachmentNonce,
  );

  // 웹은 저장 위치를 고를 수 없다 — 브라우저 다운로드로 받는다(download_storage.dart).
  if (kIsWeb) {
    return writeDownloadFile(folder: '', fileName: fileName, bytes: bytes);
  }

  final settings = session.settings;
  String? savedPath;
  if (settings.savesWithoutAsking) {
    savedPath = await writeDownloadFile(
      folder: settings.downloadFolder,
      fileName: fileName,
      bytes: bytes,
    );
  } else {
    savedPath = await FilePicker.saveFile(
      // 저장 창에 미리 채우는 이름도 이 기기에 둘 이름으로 넘긴다(download_storage.dart) — 받은
      // 이름에 폴더나 못 쓰는 글자가 섞여 있으면 저장 창이 그 폴더로 따라가거나 이름을 받지 못하고,
      // 바로 가기처럼 탐색기가 속을 읽는 형식은 글 파일로 둔다.
      fileName: savedFileName(fileName),
      initialDirectory: settings.downloadFolder.isEmpty
          ? null
          : settings.downloadFolder,
      bytes: bytes,
    );
    // 저장 창으로 받은 파일은 file_picker가 직접 쓴다 — "인터넷에서 받은 파일" 표시는 따로 붙인다.
    if (savedPath != null) await markFromInternet(savedPath);
  }

  if (savedPath != null && settings.openFolderAfterDownload) {
    await settings.openDownloadFolder();
  }
  return savedPath;
}

/// 이미지 메시지의 사진들. 서버가 첨부를 늘 목록으로 내려주지만, 아주 예전 캐시 등으로 목록이
/// 비어 있으면 메시지의 파일 칸으로 하나 만든다 — 말풍선과 뷰어가 같은 순서·번호를 쓰게 한 곳에 둔다.
List<MessageAttachment> imageAttachmentsOf(Message m) =>
    m.attachments.isNotEmpty
    ? m.attachments
    : [
        MessageAttachment(
          id: m.id,
          kind: 'image',
          fileUrl: m.fileUrl ?? '',
          fileName: m.fileName,
          fileSize: m.fileSize,
          thumbnailUrl: m.thumbnailUrl,
        ),
      ];

/// 뷰어에서 한 장을 가리키는 이름 — 메시지 id + 그 메시지 안에서 몇 번째 사진인지.
String viewerImageId(Message m, int index) => '${m.id}#$index';

/// 방에 불러와 있는 메시지들의 사진을 시간 순서대로 모은다 — 뷰어에서 앞뒤 메시지의 사진까지
/// 이어서 넘겨 본다. 지워진 메시지와 복호화하지 못한 비밀 대화 메시지는 뺀다(댓글은 이미지
/// 메시지가 아니라 애초에 안 들어온다). 비밀 대화 사진은 그 장을 볼 때 받아 복호화한다.
List<ViewerImage> roomViewerImages(Session session, List<Message> messages) {
  final images =
      messages
          .where(
            (m) =>
                m.type == MessageType.image && !m.deleted && !m.decryptFailed,
          )
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
  return [
    for (final m in images)
      for (final (i, a) in imageAttachmentsOf(m).indexed)
        // 파일 삭제로 지워진 사진은 넘겨 볼 목록에서 뺀다(번호 i는 말풍선의 칸 번호 그대로 둔다).
        if (a.isImage && !a.deleted)
          ViewerImage(
            id: viewerImageId(m, i),
            attachmentId: a.id,
            message: m,
            url: session.resolveUrl(a.fileUrl),
            fileName: a.fileName ?? 'image.png',
            fileSize: a.fileSize,
            loadBytes: m.attachmentKey == null
                ? null
                : () => fetchAttachmentBytes(
                    session: session,
                    url: session.resolveUrl(a.fileUrl),
                    attachmentKey: m.attachmentKey,
                    attachmentNonce: m.attachmentNonce,
                  ),
          ),
  ];
}

/// 한 메시지의 첨부를 전부 한 폴더에 저장한다(말풍선 아래 "전체 다운로드").
/// "저장 위치 안 물어보기"가 켜져 있으면 설정된 폴더에 바로, 아니면 **폴더를 한 번만** 물어본다
/// (파일마다 저장 창이 뜨면 여러 장일 때 번거롭다). 같은 이름이 이미 있으면 "이름 (1).png"처럼
/// 번호를 붙여 덮어쓰지 않는다. 저장한 개수와 폴더를 돌려준다(취소되면 null).
Future<({int count, String folder})?> saveAllAttachments({
  required Session session,
  required List<({String url, String fileName})> items,
  String? attachmentKey,
  String? attachmentNonce,
}) async {
  final settings = session.settings;
  // 웹은 폴더가 없다 — 파일마다 브라우저 다운로드로 받는다(download_storage.dart).
  final folder = kIsWeb
      ? ''
      : settings.savesWithoutAsking
      ? settings.downloadFolder
      : await FilePicker.getDirectoryPath(
          initialDirectory: settings.downloadFolder.isEmpty
              ? null
              : settings.downloadFolder,
        );
  if (folder == null) return null;

  var count = 0;
  for (final item in items) {
    final bytes = await fetchAttachmentBytes(
      session: session,
      url: item.url,
      attachmentKey: attachmentKey,
      attachmentNonce: attachmentNonce,
    );
    await writeDownloadFile(
      folder: folder,
      fileName: item.fileName,
      bytes: bytes,
    );
    count++;
  }
  if (settings.openFolderAfterDownload) await settings.openDownloadFolder();
  return (count: count, folder: folder);
}

/// 여러 첨부가 딸린 말풍선의 맨 아래 줄 — 오른쪽 끝에 "전체 다운로드".
class AllDownloadBar extends StatefulWidget {
  final Session session;
  final List<({String url, String fileName})> items;
  final String? attachmentKey;
  final String? attachmentNonce;

  const AllDownloadBar({
    super.key,
    required this.session,
    required this.items,
    this.attachmentKey,
    this.attachmentNonce,
  });

  @override
  State<AllDownloadBar> createState() => _AllDownloadBarState();
}

class _AllDownloadBarState extends State<AllDownloadBar> {
  bool _busy = false;

  Future<void> _downloadAll() async {
    setState(() => _busy = true);
    try {
      final ok = await confirmCellularDownload(
        context,
        session: widget.session,
        items: [for (final i in widget.items) (url: i.url, size: null)],
      );
      if (!ok) return;
      final result = await saveAllAttachments(
        session: widget.session,
        items: widget.items,
        attachmentKey: widget.attachmentKey,
        attachmentNonce: widget.attachmentNonce,
      );
      if (!mounted || result == null) return;
      showAppToast(
        context,
        result.folder.isEmpty
            ? '${result.count}개를 다운로드했습니다.'
            : '${result.count}개를 다운로드했습니다: ${displayDownloadPath(result.folder)}',
      );
    } catch (e) {
      if (mounted) showAppToast(context, '다운로드 실패: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: _busy ? null : _downloadAll,
          style: TextButton.styleFrom(
            foregroundColor: hint,
            // 바탕은 마우스를 올렸을 때(글자색 8%가 위에 겹친다)보다 연하게 깔아 둔다.
            backgroundColor: hint.withValues(alpha: 0.05),
            visualDensity: VisualDensity.compact,
            // 테마 글꼴(한글 대체 글꼴 포함)에서 크기·굵기만 바꾼다 — 맨 TextStyle을 주면 버튼 글자가
            // 테마의 대체 글꼴을 잃어 한글이 네모(□)로 나올 수 있다.
            textStyle: Theme.of(context).textTheme.labelLarge?.copyWith(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          icon: _busy
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.download_outlined, size: 16),
          label: Text('전체 다운로드 (${widget.items.length})'),
        ),
      ),
    );
  }
}

/// 한 메시지에 파일이 여러 개 딸렸을 때 — 파일 칸을 위아래로 쌓고 맨 아래에 "전체 다운로드".
class ChatFileAttachments extends StatelessWidget {
  final Session session;
  final List<MessageAttachment> attachments;
  final Message? message;
  final String? attachmentKey;
  final String? attachmentNonce;

  const ChatFileAttachments({
    super.key,
    required this.session,
    required this.attachments,
    this.message,
    this.attachmentKey,
    this.attachmentNonce,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < attachments.length; i++) ...[
          if (i > 0) const SizedBox(height: 6),
          if (attachments[i].deleted)
            Align(
              alignment: Alignment.centerLeft,
              child: DeletedFileCard(
                fileName: attachments[i].fileName,
                isImage: attachments[i].isImage,
              ),
            )
          else
            DownloadableFile(
              session: session,
              url: session.resolveUrl(attachments[i].fileUrl),
              fileName: attachments[i].fileName ?? '파일',
              message: message,
              attachmentId: attachments[i].id,
              attachmentKey: attachmentKey,
              attachmentNonce: attachmentNonce,
            ),
        ],
        if (attachments.where((a) => !a.deleted).length > 1)
          AllDownloadBar(
            session: session,
            items: [
              for (final a in attachments)
                if (!a.deleted)
                  (
                    url: session.resolveUrl(a.fileUrl),
                    fileName: a.fileName ?? '파일',
                  ),
            ],
            attachmentKey: attachmentKey,
            attachmentNonce: attachmentNonce,
          ),
      ],
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

  /// 주면(파일 패널의 "메시지" 화면) 마우스를 올렸을 때 다운로드 대신 파일 목록 줄과 같은
  /// 즐겨찾기 · 더보기(파일 전달·다운로드·즐겨찾기·원본 파일 보기)를 띄운다.
  final FileActions? actions;
  final bool favorited;
  final VoidCallback? onToggleFavorite;

  /// 누르면 기본 뷰어(이 한 장) 대신 이걸 부른다 — 앞뒤 사진까지 넘기는 뷰어를 열 때.
  final VoidCallback? onOpen;

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
    this.actions,
    this.favorited = false,
    this.onToggleFavorite,
    this.onOpen,
  });

  @override
  State<DownloadableImage> createState() => _DownloadableImageState();
}

class _DownloadableImageState extends State<DownloadableImage> {
  bool _hovering = false;

  /// 더보기 메뉴가 떠 있는 동안에는 툴바를 계속 보여준다(파일 목록 줄과 같은 이유).
  bool _menuOpen = false;
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
        session: widget.session,
        url: _previewUrl,
        attachmentKey: _previewKey,
        attachmentNonce: _previewNonce,
      );
    }
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final ok = await confirmCellularDownload(
        context,
        session: widget.session,
        items: [(url: widget.url, size: null)],
      );
      if (!ok) return;
      final savedPath = await saveAttachment(
        session: widget.session,
        url: widget.url,
        fileName: widget.fileName,
        attachmentKey: widget.attachmentKey,
        attachmentNonce: widget.attachmentNonce,
      );
      if (!mounted) return;
      if (savedPath != null) {
        showAppToast(context, '다운로드 완료: ${displayDownloadPath(savedPath)}');
      }
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '다운로드 실패: $e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  void _open() {
    final onOpen = widget.onOpen;
    if (onOpen != null) return onOpen();
    // 뷰어는 늘 창 전체(루트 Navigator)에 — PC 할 일 패널 안 화면(중첩 Navigator)에서 열어도 패널 폭에 갇히지 않게.
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen.single(
          imageUrl: widget.url,
          // 원본이 암호화돼 있으면(비밀 대화) 여는 시점에 새로 다운로드+복호화한다 — 미리보기는
          // 이미 축소 썸네일로 봤으니 굳이 미리 받아둘 필요가 없다.
          imageBytesFuture: widget.attachmentKey != null
              ? fetchAttachmentBytes(
                  session: widget.session,
                  url: widget.url,
                  attachmentKey: widget.attachmentKey,
                  attachmentNonce: widget.attachmentNonce,
                )
              : null,
        ),
      ),
    );
  }

  /// 즐겨찾기 · 더보기 — 파일 목록 줄과 같다. 즐겨찾기한 사진은 마우스를 올리지 않아도 별이 보인다.
  Widget _fileToolbar(BuildContext context, FileActions actions) {
    final show = _hovering || _menuOpen;
    if (!show && !widget.favorited) return const SizedBox.shrink();
    return Positioned(
      right: 6,
      top: 6,
      child: HoverToolbar(
        children: [
          HoverToolbarButton(
            icon: widget.favorited ? Icons.star : Icons.star_border,
            color: widget.favorited ? Colors.amber : null,
            tooltip: widget.favorited ? '즐겨찾기 빼기' : '즐겨찾기',
            onPressed: widget.onToggleFavorite,
          ),
          if (show)
            HoverToolbarButton(
              icon: Icons.more_vert,
              tooltip: '더보기',
              onMenuOpenChanged: (v) => setState(() => _menuOpen = v),
              menuChildren: fileActionMenuItems(
                context,
                actions,
                isImage: true,
                favorited: widget.favorited,
                onToggleFavorite: widget.onToggleFavorite,
              ),
            ),
        ],
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
                // 채팅 썸네일과 같은 규칙 — 자르지 않고 통째로 보여주되 원본보다 크게
                // 늘리지는 않는다(남는 자리는 아래 배경색).
                fit: BoxFit.scaleDown,
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
            fit: BoxFit.scaleDown,
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
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: image,
              ),
            ),
            if (widget.actions != null)
              _fileToolbar(context, widget.actions!)
            else if (_hovering)
              Positioned(
                right: 6,
                top: 6,
                child: HoverToolbar(
                  children: [
                    HoverToolbarButton(
                      icon: Icons.download_outlined,
                      tooltip: '다운로드',
                      busy: _downloading,
                      onPressed: _download,
                    ),
                  ],
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

/// 미리보기 **전체 높이**의 상한 — 사진 묶음이 대화창을 다 먹지 않게 한다. **줄 수**(3장마다
/// 줄바꿈되는 행 개수)를 키로 쓴다: 1~3장(1줄)은 170, 4~6장(2줄)은 300, 7장 이상(3줄)은 420.
/// 줄이 여러 개면 이 값을 줄들이 나눠 갖는다(칸 하나의 높이가 아니다 — 9장이면 3줄 합쳐서
/// 420을 넘지 않는다).
const kChatImageMaxHeights = {1: 170.0, 2: 300.0, 3: 420.0};

double chatImageMaxHeight(int rows) =>
    kChatImageMaxHeights[rows] ?? kChatImageMaxHeights[3]!;

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

  /// 여러 장일 때 격자 아래에 "전체 다운로드" 줄을 둘지 — 기본은 둔다(말풍선). 할 일 상세처럼 전부 받기를 다른 곳
  /// (••• → 파일 다운로드)이 맡는 화면은 끈다.
  final bool showDownloadAll;

  /// 썸네일 도구모음의 "댓글" — 주면 그 메시지의 댓글을 연다(메시지 말풍선의 댓글 버튼과 같다). 안 주면 버튼이 없다.
  final void Function(Message message)? onOpenThread;

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
    this.showDownloadAll = true,
    this.onOpenThread,
  });

  VoidCallback? get _onComment {
    final message = this.message, onOpenThread = this.onOpenThread;
    if (message == null || onOpenThread == null) return null;
    return () => onOpenThread(message);
  }

  /// 이 말풍선의 사진만 넘겨볼 때의 목록 — 비밀 대화면 그 장을 볼 때 원본을 받아 복호화한다.
  List<ViewerImage> _viewerImages() => [
    for (final (i, a) in attachments.indexed)
      if (!a.deleted)
        ViewerImage(
          id: message == null ? null : viewerImageId(message!, i),
          attachmentId: a.id,
          message: message,
          url: session.resolveUrl(a.fileUrl),
          fileName: a.fileName ?? 'image.png',
          fileSize: a.fileSize,
          loadBytes: attachmentKey == null
              ? null
              : () => fetchAttachmentBytes(
                  session: session,
                  url: session.resolveUrl(a.fileUrl),
                  attachmentKey: attachmentKey,
                  attachmentNonce: attachmentNonce,
                ),
        ),
  ];

  void _open(BuildContext context, int index) {
    // 뷰어는 늘 창 전체(루트 Navigator)에 — PC 할 일 패널 안 화면(중첩 Navigator)에서 열어도 패널 폭에 갇히지 않게.
    Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute(builder: (_) => _viewer(index)));
  }

  /// 채팅방 말풍선에서 열면 그 방의 앞뒤 메시지 사진까지 이어서 넘겨 보고, 맨 앞에 닿으면 과거
  /// 메시지를 더 불러온다. 방을 모르거나 그 방 목록에 이 메시지가 없으면 이 말풍선의 사진만.
  Widget _viewer(int index) {
    final room = this.room, message = this.message;
    if (room != null && message != null) {
      final controller = session.controllerFor(room);
      List<ViewerImage> all() => roomViewerImages(session, controller.messages);
      final images = all();
      final start = images.indexWhere(
        (v) => v.id == viewerImageId(message, index),
      );
      if (start >= 0) {
        return ImageViewerScreen(
          images: images,
          initialIndex: start,
          session: session,
          message: message,
          room: room,
          source: ViewerImageSource(
            changes: controller,
            images: all,
            hasOlder: () => controller.hasMoreHistory,
            loadOlder: controller.loadOlderMessages,
          ),
        );
      }
    }
    // 지워진 사진은 목록에서 빠지므로 눌린 칸(index)이 목록에서 몇 번째인지 다시 센다.
    final live = attachments.take(index).where((a) => !a.deleted).length;
    return ImageViewerScreen(
      images: _viewerImages(),
      initialIndex: live,
      session: session,
      message: message,
      room: room,
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
          if (attachments.first.deleted) {
            return Align(
              alignment: Alignment.centerLeft,
              child: DeletedFileCard(
                fileName: attachments.first.fileName,
                isImage: true,
              ),
            );
          }
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
            onComment: _onComment,
          );
        }
        const gap = 4.0;
        final columns = math.min(kChatImageGridColumns, attachments.length);
        final cell = (width - gap * (columns - 1)) / columns;
        // 3장마다 줄이 바뀌므로, 장수를 3으로 나눠 올림한 값이 줄 수다. 전체 높이 상한은
        // 3줄까지만 커지고(4줄 이상이면 3줄과 같은 420), 그 상한을 실제 줄 수가 나눠 갖는다
        // — 그래서 몇 장을 보내든 사진 묶음 전체 높이가 상한을 넘지 않는다.
        final rows = ((attachments.length - 1) ~/ kChatImageGridColumns) + 1;
        final budget = chatImageMaxHeight(math.min(rows, 3));
        // 칸 하나의 높이 — 칸 폭보다 높아지지는 않게 해서 세로로 길쭉한 칸이 생기지 않게
        // 한다. 모든 칸이 같은 값을 쓰므로, 같은 사진을 다시 보내면 항상 같은 모양으로
        // 그려진다(원본 비율을 비동기로 재서 칸마다 높이를 다르게 잡던 방식은 측정 시점에
        // 따라 같은 사진도 다르게 보이는 문제가 있었다).
        final tileHeight = math.min(cell, (budget - gap * (rows - 1)) / rows);
        return SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (var i = 0; i < attachments.length; i++)
                    if (attachments[i].deleted)
                      // 지워진 사진 칸 — 자리는 그대로 두고 흐린 카드로 바꾼다.
                      DeletedFileCard(
                        compact: true,
                        isImage: true,
                        width: cell,
                        height: tileHeight,
                      )
                    else
                      _ChatImageTile(
                        session: session,
                        message: message,
                        attachment: attachments[i],
                        width: cell,
                        fixedHeight: tileHeight,
                        onTap: () => _open(context, i),
                        onComment: _onComment,
                      ),
                ],
              ),
              // 여러 장이면 말풍선 아래를 한 줄 늘려 오른쪽 끝에 "전체 다운로드"를 둔다(지워진 사진은 뺀다).
              if (showDownloadAll && attachments.any((a) => !a.deleted))
                AllDownloadBar(
                  session: session,
                  items: [
                    for (final a in attachments)
                      if (!a.deleted)
                        (
                          url: session.resolveUrl(a.fileUrl),
                          fileName: a.fileName ?? 'image.png',
                        ),
                  ],
                  attachmentKey: attachmentKey,
                  attachmentNonce: attachmentNonce,
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 미리보기 한 칸.
///
/// [fixedHeight]를 주면(격자 — 여러 장) 모든 칸이 그 높이로 똑같이 그려지고, 칸에 남는 자리가
/// 없도록 잘라서 채운다(BoxFit.cover). 안 주면(한 장짜리) 원본 비율 그대로 그리되 [maxHeight]를
/// 넘지 않고, **원본보다 크게 늘리지도 않는다** — 원본이 작으면 칸 자체가 원본 크기로 줄어서
/// 말풍선에 여백이 남지 않는다.
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

  /// 도구모음의 "댓글" — null이면 버튼이 없다.
  final VoidCallback? onComment;

  const _ChatImageTile({
    required this.session,
    required this.attachment,
    this.message,
    required this.width,
    required this.onTap,
    this.onComment,
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
  bool _menuOpen = false;
  bool _downloading = false;
  Future<Uint8List>? _previewBytes;

  /// 미리보기 이미지(썸네일이 있으면 썸네일, 없으면 원본)의 가로/세로 비 — 한 장짜리 칸의
  /// 세로를 이 비율로 잡는다. 알기 전에는 아래 기본값으로 자리를 잡는다.
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
        session: widget.session,
        url: _previewUrl,
        attachmentKey: _previewKey,
        attachmentNonce: _previewNonce,
      );
    } else if (widget.fixedHeight == null) {
      // 한 장짜리만 칸 세로를 원본 비율로 잡으므로 미리 크기를 알아본다(격자는 모든 칸이
      // 같은 고정 높이라 원본 크기를 몰라도 된다).
      _listenForRatio();
    }
  }

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
      attachmentId: widget.attachment.id,
      attachmentKey: widget.attachmentKey,
      attachmentNonce: widget.attachmentNonce,
    );
  }

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final url = widget.session.resolveUrl(widget.attachment.fileUrl);
      final ok = await confirmCellularDownload(
        context,
        session: widget.session,
        items: [(url: url, size: widget.attachment.fileSize)],
      );
      if (!ok) return;
      final savedPath = await saveAttachment(
        session: widget.session,
        url: url,
        fileName: widget.attachment.fileName ?? 'image.png',
        attachmentKey: widget.attachmentKey,
        attachmentNonce: widget.attachmentNonce,
      );
      if (!mounted) return;
      if (savedPath != null) {
        showAppToast(context, '다운로드 완료: ${displayDownloadPath(savedPath)}');
      }
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '다운로드 실패: $e');
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fixedHeight = widget.fixedHeight;
    final double width;
    final double height;
    if (fixedHeight != null) {
      // 격자 칸 — 모든 칸이 같은 크기(부모가 정한 값)라 줄이 가지런하다.
      width = widget.width;
      height = fixedHeight;
    } else {
      // 한 장짜리 — 가로는 원본 크기와 상관없이 항상 칸 폭([kChatImageMaxWidth], 창이 좁으면
      // 그만큼)을 쓰고, 세로만 원본 비율에 맞춘다. 그래서 위아래 여백 없이 꽉 차고, 세로로
      // 아주 긴 사진만 [maxHeight]에서 잘린다. 비율을 아직 모르면 가로:세로 = 3:2쯤으로
      // 자리를 잡아둔다(알게 되면 그 비율로 바뀐다).
      width = widget.width;
      height = math.min(widget.maxHeight, width / (_ratio ?? 1.5));
    }
    // 사진을 자르지 않는다 — 칸보다 크면 통째로 들어가게 줄이고, 칸보다 작으면 늘리지 않고
    // 원본 크기 그대로 그린다(BoxFit.scaleDown). 어느 쪽이든 칸에 남는 자리는 배경색으로
    // 채워진다.
    const fit = BoxFit.scaleDown;

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
                fit: fit,
              );
            },
          )
        : CachedNetworkImage(
            imageUrl: _previewUrl,
            width: width,
            height: height,
            fit: fit,
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
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: SizedBox(width: width, height: height, child: image),
              ),
            ),
            // 메뉴가 떠 있는 동안에는 툴바를 계속 보여준다 — 마우스를 메뉴로 옮기면 썸네일
            // 밖으로 나간 것으로 잡혀서, 안 붙잡으면 툴바가 사라지며 메뉴까지 닫힌다.
            if (_hovering || _menuOpen)
              Positioned(
                right: 6,
                top: 6,
                // 이미지 뷰어 오른쪽 위와 같은 도구모음(댓글·다운로드·더보기)을 말풍선 호버 툴바와 같은
                // 상자 하나에 담는다.
                child: HoverToolbar(
                  children: [
                    if (widget.onComment != null)
                      HoverToolbarButton(
                        icon: Icons.mode_comment_outlined,
                        tooltip: '댓글',
                        onPressed: widget.onComment,
                      ),
                    HoverToolbarButton(
                      icon: Icons.download_outlined,
                      tooltip: '다운로드',
                      busy: _downloading,
                      onPressed: _download,
                    ),
                    if (widget.message != null)
                      HoverToolbarButton(
                        icon: Icons.more_vert,
                        tooltip: '더보기',
                        onMenuOpenChanged: (v) => setState(() => _menuOpen = v),
                        menuChildren: imageActionMenuItems(
                          context,
                          _actions()!,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 이미지 도구모음(채팅 썸네일과 이미지 뷰어 오른쪽 위 — 댓글 · 다운로드 · 더보기)의 "더보기" 항목들 — 파일 전달 ·
/// 인쇄 · 즐겨찾기 · 복사 · 원본 파일 보기 (+올린 본인·팀 관리자에게는 "삭제"). 댓글·다운로드는 도구모음에 버튼으로
/// 따로 있어서 여기엔 없다.
List<Widget> imageActionMenuItems(BuildContext context, FileActions actions) =>
    [
      hoverMenuItem(
        icon: Icons.send_outlined,
        label: '파일 전달',
        onPressed: () => actions.forward(context),
      ),
      hoverMenuItem(
        icon: Icons.print_outlined,
        label: '인쇄',
        onPressed: () => actions.printImage(context),
      ),
      hoverMenuItem(
        icon: Icons.star_border,
        label: '즐겨찾기',
        onPressed: () => actions.toggleFavorite(context),
      ),
      if (canCopyImageToClipboard)
        hoverMenuItem(
          icon: Icons.copy_outlined,
          label: '복사',
          onPressed: () => actions.copyImage(context),
        ),
      hoverMenuItem(
        icon: Icons.image_outlined,
        label: '원본 파일 보기',
        onPressed: () => actions.openOriginal(context),
      ),
      // 올린 본인과 팀 관리자에게만 — 파일만 지우고 메시지와 댓글은 남는다.
      if (actions.canDelete) ...[
        hoverMenuDivider(),
        hoverMenuItem(
          icon: Icons.delete_outline,
          label: '삭제',
          color: Theme.of(context).colorScheme.error,
          onPressed: () => actions.deleteFile(context),
        ),
      ],
    ];

/// 첨부(이미지/파일) "더보기" 메뉴의 항목들 — 파일 전달 · 다운로드 · 즐겨찾기 (+이미지는
/// "복사"(클립보드에 이미지로)·"원본 파일 보기"까지, 올린 본인·팀 관리자에게는 "삭제"까지). 파일은 누르면 어차피 원본을 받아서 여는 동작이라 그 항목이 없다.
/// 별 표시를 따로 들고 있는 화면(파일 패널)은 [favorited]·[onToggleFavorite]를 줘서 메뉴의
/// 즐겨찾기도 그 별과 같이 바뀌게 한다(안 주면 서버에만 토글하고 알약으로 알린다).
List<Widget> fileActionMenuItems(
  BuildContext context,
  FileActions actions, {
  required bool isImage,
  bool favorited = false,
  VoidCallback? onToggleFavorite,
}) => [
  hoverMenuItem(
    icon: Icons.send_outlined,
    label: '파일 전달',
    onPressed: () => actions.forward(context),
  ),
  hoverMenuItem(
    icon: Icons.download_outlined,
    label: '다운로드',
    onPressed: () => actions.download(context),
  ),
  hoverMenuItem(
    icon: favorited ? Icons.star : Icons.star_border,
    label: favorited ? '즐겨찾기 빼기' : '즐겨찾기',
    onPressed: onToggleFavorite ?? () => actions.toggleFavorite(context),
  ),
  if (isImage && canCopyImageToClipboard)
    hoverMenuItem(
      icon: Icons.copy_outlined,
      label: '복사',
      onPressed: () => actions.copyImage(context),
    ),
  if (isImage)
    hoverMenuItem(
      icon: Icons.image_outlined,
      label: '원본 파일 보기',
      onPressed: () => actions.openOriginal(context),
    ),
  // 올린 본인과 팀 관리자에게만 — 파일만 지우고 메시지와 댓글은 남는다.
  if (actions.canDelete) ...[
    hoverMenuDivider(),
    hoverMenuItem(
      icon: Icons.delete_outline,
      label: '삭제',
      color: Theme.of(context).colorScheme.error,
      onPressed: () => actions.deleteFile(context),
    ),
  ],
];

/// 채팅/댓글에 올라온 파일 하나. 누르면 항상 먼저 전체를 다 받은 뒤에 PDF/텍스트는 인앱
/// 뷰어로, 그 외는 외부 앱으로 열고(실행될 수 있는 형식은 열지 않고 폴더에서 보여 준다 — _open
/// 참고), 마우스를 올리면 오른쪽 위에 다운로드 버튼이 뜬다.
class DownloadableFile extends StatefulWidget {
  final Session session;
  final String url;
  final String fileName;

  /// "더보기"(파일 전달·다운로드·즐겨찾기·원본 파일 보기)에 필요하다 — 이미지 썸네일과
  /// 같은 규칙으로, 안 주면 다운로드 버튼만 보인다(파일 모아보기 미리보기 등).
  final Message? message;

  /// 파일 삭제가 가리킬 첨부 id — 안 주면 메시지 id(첨부 하나짜리 옛 메시지).
  final String? attachmentId;

  /// 파일을 지운 뒤(파일 패널의 미리보기 화면이 목록을 다시 받는다).
  final VoidCallback? onDeleted;

  /// DownloadableImage와 동일한 의미 — 있으면 서버 URL은 암호화된 바이트라, 복호화해야
  /// 실제 내용을 볼 수 있다.
  final String? attachmentKey;
  final String? attachmentNonce;
  const DownloadableFile({
    super.key,
    required this.session,
    required this.url,
    required this.fileName,
    this.message,
    this.attachmentId,
    this.onDeleted,
    this.attachmentKey,
    this.attachmentNonce,
  });

  @override
  State<DownloadableFile> createState() => _DownloadableFileState();
}

class _DownloadableFileState extends State<DownloadableFile> {
  bool _hovering = false;
  bool _menuOpen = false;
  bool _downloading = false;
  bool _opening = false;

  Future<void> _download() async {
    setState(() => _downloading = true);
    try {
      final ok = await confirmCellularDownload(
        context,
        session: widget.session,
        items: [(url: widget.url, size: null)],
      );
      if (!ok) return;
      final savedPath = await saveAttachment(
        session: widget.session,
        url: widget.url,
        fileName: widget.fileName,
        attachmentKey: widget.attachmentKey,
        attachmentNonce: widget.attachmentNonce,
      );
      if (!mounted) return;
      if (savedPath != null) {
        showAppToast(context, '다운로드 완료: ${displayDownloadPath(savedPath)}');
      }
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '다운로드 실패: $e');
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
      final ok = await confirmCellularDownload(
        context,
        session: widget.session,
        items: [(url: widget.url, size: null)],
      );
      if (!ok) return;
      final bytes = await fetchAttachmentBytes(
        session: widget.session,
        url: widget.url,
        attachmentKey: widget.attachmentKey,
        attachmentNonce: widget.attachmentNonce,
      );
      if (!mounted) return;

      if (_isInAppViewable(widget.fileName)) {
        final ext = widget.fileName.split('.').last.toLowerCase();
        // 뷰어는 늘 창 전체(루트 Navigator)에 — PC 할 일 패널 안 화면(중첩 Navigator)에서 열어도 패널 폭에 갇히지 않게.
        await Navigator.of(context, rootNavigator: true).push(
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
      // 다운로드 폴더에 남아있게), 지정 안 했으면 원래대로 임시 폴더로 폴백한다. 임시 폴더도
      // 이 앱만의 폴더이고, 받은 이름은 다듬어서 그 폴더 바로 아래에만 쓴다(downloadTempFolder·
      // writeDownloadFile). 웹은 폴더 없이 새 탭으로 연다.
      final isSecret = widget.attachmentKey != null;
      final downloadFolder = widget.session.settings.downloadFolder;
      final path = await writeDownloadFile(
        folder: !isSecret && downloadFolder.isNotEmpty
            ? downloadFolder
            : await downloadTempFolder(),
        fileName: widget.fileName,
        bytes: bytes,
        reuseIdentical: true,
      );
      // 실행될 수 있는 형식은 열지 않고 폴더에서 보여 준다 — 그 까닭을 알린다.
      final notice = await openLocalFile(path);
      if (notice != null && mounted) {
        showAppToast(context, notice, duration: const Duration(seconds: 4));
      }
    } catch (e) {
      if (!mounted) return;
      showAppToast(context, '열기 실패: $e');
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
            // 메뉴가 떠 있는 동안에는 툴바를 계속 보여준다(이미지 썸네일과 같은 이유).
            if (_hovering || _menuOpen)
              Positioned(
                right: -6,
                top: -6,
                // 이미지 썸네일과 같은 툴바 — 다운로드 + (메시지를 알면) 더보기.
                child: HoverToolbar(
                  children: [
                    HoverToolbarButton(
                      icon: Icons.download_outlined,
                      tooltip: '다운로드',
                      busy: _downloading,
                      onPressed: _download,
                    ),
                    if (widget.message != null)
                      HoverToolbarButton(
                        icon: Icons.more_vert,
                        tooltip: '더보기',
                        onMenuOpenChanged: (v) => setState(() => _menuOpen = v),
                        menuChildren: fileActionMenuItems(
                          context,
                          FileActions(
                            session: widget.session,
                            message: widget.message!,
                            url: widget.url,
                            fileName: widget.fileName,
                            attachmentId: widget.attachmentId,
                            onDeleted: widget.onDeleted,
                            attachmentKey: widget.attachmentKey,
                            attachmentNonce: widget.attachmentNonce,
                          ),
                          isImage: false,
                        ),
                      ),
                  ],
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
