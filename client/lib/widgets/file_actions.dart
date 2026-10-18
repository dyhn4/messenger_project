import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../models/message.dart';
import '../services/clipboard_image.dart';
import '../services/download_progress.dart' show DownloadCancelled;
import '../services/download_storage.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'attachment_widgets.dart';
import 'data_usage_warning.dart';
import 'message_actions.dart' show pushMessageForwardScreen;
import '../l10n/tr.dart';

/// "이 파일을 삭제할까요?" 확인 대화상자 — 삭제하겠다고 하면 true. 파일을 지워도 그 파일에 달린 댓글은 남는다.
Future<bool> confirmDeleteFile(BuildContext context) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(tr('파일 삭제')),
      content: Text(tr('이 파일을 삭제할까요? 파일에 달린 댓글은 남아 있습니다.')),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(tr('취소')),
        ),
        FilledButton(
          key: const ValueKey('confirm-delete-file'),
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(tr('삭제')),
        ),
      ],
    ),
  );
  return ok ?? false;
}

/// 모바일에서 파일 줄을 길게 눌렀을 때 뜨는 시트 — 더보기 메뉴(fileActionMenuItems)와 같은 일을 목록으로 보여 준다.
/// "삭제"는 올린 본인·팀 관리자에게만 나온다.
Future<void> showFileActionSheet(
  BuildContext context,
  FileActions actions, {
  required bool isImage,
  bool favorited = false,
  VoidCallback? onToggleFavorite,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) {
      Widget tile(
        IconData icon,
        String label,
        VoidCallback onTap, {
        Color? color,
      }) => ListTile(
        leading: Icon(icon, color: color),
        title: Text(label, style: TextStyle(color: color)),
        onTap: () {
          Navigator.of(sheetContext).pop();
          onTap();
        },
      );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            tile(
              Icons.send_outlined,
              tr('파일 전달'),
              () => actions.forward(context),
            ),
            tile(
              Icons.download_outlined,
              tr('다운로드'),
              () => actions.download(context),
            ),
            tile(
              favorited ? Icons.star : Icons.star_border,
              favorited ? tr('즐겨찾기 빼기') : tr('즐겨찾기'),
              onToggleFavorite ?? () => actions.toggleFavorite(context),
            ),
            if (isImage && canCopyImageToClipboard)
              tile(
                Icons.copy_outlined,
                tr('복사'),
                () => actions.copyImage(context),
              ),
            if (isImage)
              tile(
                Icons.image_outlined,
                tr('원본 파일 보기'),
                () => actions.openOriginal(context),
              ),
            if (actions.canDelete)
              tile(
                Icons.delete_outline,
                tr('삭제'),
                () => actions.deleteFile(context),
                color: Theme.of(sheetContext).colorScheme.error,
              ),
          ],
        ),
      );
    },
  );
}

/// 첨부 하나에 대해 할 수 있는 일들 — 썸네일의 "더보기" 메뉴와 뷰어 상단 버튼이 같은 동작을
/// 쓰도록 한곳에 모았다. 비밀 대화(E2EE) 첨부는 원본이 암호문이라, 받아서 복호화한 다음에
/// 저장·인쇄·열기를 한다.
class FileActions {
  final Session session;

  /// 이 첨부가 딸린 메시지 — "파일 전달"과 즐겨찾기가 메시지 단위로 동작한다.
  final Message message;
  final String url;
  final String fileName;
  final String? attachmentKey;
  final String? attachmentNonce;

  /// 파일 삭제가 가리킬 첨부 id — 첨부 하나짜리 옛 메시지는 메시지 id(안 주면 그렇게 본다).
  final String? attachmentId;

  /// 파일을 지운 뒤 — 목록을 쓰는 화면(파일 패널·즐겨찾기)이 줄을 빼거나 다시 불러온다. 말풍선은 서버의
  /// message:edited로 알아서 바뀐다.
  final VoidCallback? onDeleted;

  const FileActions({
    required this.session,
    required this.message,
    required this.url,
    required this.fileName,
    this.attachmentKey,
    this.attachmentNonce,
    this.attachmentId,
    this.onDeleted,
  });

  /// 이 파일을 지울 수 있는 사람인지 — 올린 본인(= 그 메시지를 보낸 사람) 또는 팀 관리자. 서버가 최종 판단하고,
  /// 비밀 대화는 서버가 내용을 몰라 관리자도 못 지운다.
  bool get canDelete {
    if (message.deleted || message.type == MessageType.comment) return false;
    final me = session.userId;
    if (me != null && message.senderId == me) return true;
    final secret = session.rooms
        .where((r) => r.id == message.roomId)
        .any((r) => r.isSecret);
    return session.canModerateContent && !secret;
  }

  /// 확인을 받고 파일을 지운다 — 지웠으면 true. 메시지와 댓글은 남는다.
  Future<bool> deleteFile(BuildContext context) async {
    final ok = await confirmDeleteFile(context);
    if (!ok) return false;
    try {
      await session.api!.deleteMessageFile(
        message.id,
        attachmentId ?? message.id,
      );
    } catch (e) {
      if (context.mounted) {
        showAppToast(context, tr('파일을 삭제하지 못했습니다: {e}', {'e': e}));
      }
      return false;
    }
    // 서버가 이 파일의 즐겨찾기 항목을 정리했으니 즐겨찾기 화면은 다음에 보일 때 다시 받는다.
    session.favorites.invalidate();
    onDeleted?.call();
    if (context.mounted) showAppToast(context, tr('파일을 삭제했습니다.'));
    return true;
  }

  Future<Uint8List> _bytes() => fetchAttachmentBytes(
    session: session,
    url: url,
    attachmentKey: attachmentKey,
    attachmentNonce: attachmentNonce,
  );

  /// 다른 대화방으로 이 파일을 전달한다(기존 "메시지 전달" 화면을 그대로 쓴다).
  void forward(BuildContext context) => pushMessageForwardScreen(
    context,
    session: session,
    message: message,
    senderDisplayName: message.senderName,
  );

  Future<void> download(BuildContext context) async {
    try {
      final ok = await confirmCellularDownload(
        context,
        session: session,
        items: [(url: url, size: null)],
      );
      if (!ok || !context.mounted) return;
      final savedPath = await saveAttachment(
        session: session,
        url: url,
        fileName: fileName,
        attachmentKey: attachmentKey,
        attachmentNonce: attachmentNonce,
      );
      if (!context.mounted || savedPath == null) return;
      showAppToast(
        context,
        tr('다운로드 완료: {p0}', {'p0': displayDownloadPath(savedPath)}),
      );
    } on DownloadCancelled catch (e) {
      // 진행 카드의 X로 멈췄다.
      if (context.mounted) showAppToast(context, '$e');
    } catch (e) {
      if (context.mounted) showAppToast(context, tr('다운로드 실패: {e}', {'e': e}));
    }
  }

  /// 이미지 복사 — 원본을 받아(비밀 대화면 복호화해서) 시스템 클립보드에 이미지로 올린다. 다른 프로그램이나
  /// 대화 입력칸에 그대로 붙여넣을 수 있다.
  Future<void> copyImage(BuildContext context) async {
    try {
      await copyImageToClipboard(_bytes());
      if (context.mounted) showAppToast(context, tr('이미지를 복사했습니다.'));
    } catch (e) {
      if (context.mounted) {
        showAppToast(context, tr('이미지를 복사하지 못했습니다: {e}', {'e': e}));
      }
    }
  }

  /// 즐겨찾기 토글 — 넣었는지 뺐는지를 돌려준다(화면이 별 아이콘을 바꾸는 데 쓴다).
  Future<bool?> toggleFavorite(BuildContext context) async {
    try {
      final on = await session.api!.toggleFavoriteFile(
        message.id,
        fileUrl: url,
        fileName: fileName,
      );
      if (context.mounted) {
        showAppToast(context, on ? tr('즐겨찾기에 담았습니다.') : tr('즐겨찾기에서 뺐습니다.'));
      }
      return on;
    } catch (e) {
      if (context.mounted) {
        showAppToast(context, tr('즐겨찾기에 담지 못했습니다: {e}', {'e': e}));
      }
      return null;
    }
  }

  /// 원본 파일 보기 — 원본을 다운로드 폴더에 받아두고, 그 파일을 PC 기본 프로그램(이미지면
  /// 기본 이미지 앱)으로 연다. 다운로드 폴더를 아직 안 정했으면 임시 폴더에 받는다.
  /// 브라우저로 URL을 여는 대신 파일로 받아서 여는 이유: 비밀 대화는 서버의 파일이 암호문
  /// 이라 그냥 열면 못 보고, 평문 방도 브라우저가 아니라 기본 앱으로 열리는 게 자연스럽다.
  /// 즐겨찾기의 파일은 이미지가 아니어도 이걸로 열리니, 실행될 수 있는 형식은 열지 않고 폴더에서
  /// 보여 준다(openLocalFile).
  Future<void> openOriginal(BuildContext context) async {
    try {
      final ok = await confirmCellularDownload(
        context,
        session: session,
        items: [(url: url, size: null)],
      );
      if (!ok) return;
      final bytes = await _bytes();
      final folder = session.settings.downloadFolder;
      final path = await writeDownloadFile(
        folder: folder.isEmpty ? await downloadTempFolder() : folder,
        fileName: fileName,
        bytes: bytes,
        reuseIdentical: true,
      );
      final notice = await openLocalFile(path);
      if (notice != null && context.mounted) {
        showAppToast(context, notice, duration: const Duration(seconds: 4));
      }
    } catch (e) {
      if (context.mounted) {
        showAppToast(context, tr('원본을 열지 못했습니다: {e}', {'e': e}));
      }
    }
  }

  /// 인쇄 미리보기 — 이미지 한 장을 한 페이지에 비율 그대로 얹어 보낸다.
  Future<void> printImage(BuildContext context) async {
    try {
      final bytes = await _bytes();
      await Printing.layoutPdf(
        name: fileName,
        onLayout: (format) async {
          final doc = pw.Document();
          final image = pw.MemoryImage(bytes);
          doc.addPage(
            pw.Page(
              pageFormat: format,
              build: (context) =>
                  pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
            ),
          );
          return doc.save();
        },
      );
    } catch (e) {
      if (context.mounted) {
        showAppToast(context, tr('인쇄하지 못했습니다: {e}', {'e': e}));
      }
    }
  }
}
