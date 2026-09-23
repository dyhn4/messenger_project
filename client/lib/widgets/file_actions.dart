import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/message.dart';
import '../services/session.dart';
import 'app_toast.dart';
import 'attachment_widgets.dart';
import 'message_actions.dart' show pushMessageForwardScreen;

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

  const FileActions({
    required this.session,
    required this.message,
    required this.url,
    required this.fileName,
    this.attachmentKey,
    this.attachmentNonce,
  });

  Future<Uint8List> _bytes() => fetchAttachmentBytes(
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
      final savedPath = await saveAttachment(
        session: session,
        url: url,
        fileName: fileName,
        attachmentKey: attachmentKey,
        attachmentNonce: attachmentNonce,
      );
      if (!context.mounted || savedPath == null) return;
      showAppToast(context, '다운로드 완료: $savedPath');
    } catch (e) {
      if (context.mounted) showAppToast(context, '다운로드 실패: $e');
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
        showAppToast(context, on ? '즐겨찾기에 담았습니다.' : '즐겨찾기에서 뺐습니다.');
      }
      return on;
    } catch (e) {
      if (context.mounted) showAppToast(context, '즐겨찾기에 담지 못했습니다: $e');
      return null;
    }
  }

  /// 원본 파일 보기 — 축소 미리보기가 아니라 원본을 OS 기본 프로그램으로 연다.
  /// 비밀 대화는 서버의 파일이 암호문이라 임시 파일로 풀어서 연다.
  Future<void> openOriginal(BuildContext context) async {
    try {
      if (attachmentKey == null) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        return;
      }
      final bytes = await _bytes();
      final path =
          '${Directory.systemTemp.path}${Platform.pathSeparator}$fileName';
      await File(path).writeAsBytes(bytes);
      await launchUrl(Uri.file(path), mode: LaunchMode.externalApplication);
    } catch (e) {
      if (context.mounted) showAppToast(context, '원본을 열지 못했습니다: $e');
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
      if (context.mounted) showAppToast(context, '인쇄하지 못했습니다: $e');
    }
  }
}
