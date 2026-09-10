import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart';

/// PDF 첨부 인앱 뷰어. 채팅 버블에서 .pdf 파일명을 탭하면 엽니다(그 외 확장자는 여전히
/// DownloadableFile이 외부 앱으로 연다 — attachment_widgets.dart의 _isInAppViewable 참고).
///
/// [bytesFuture]로 받는 이유는 ImageViewerScreen과 같다 — 비밀 대화 첨부는 서버가 암호화된
/// 바이트만 갖고 있어서, 이 화면을 열 때(탭하는 시점)에야 다운로드+복호화한다.
class PdfViewerScreen extends StatefulWidget {
  final String fileName;
  final Future<Uint8List> bytesFuture;
  const PdfViewerScreen({
    super.key,
    required this.fileName,
    required this.bytesFuture,
  });

  @override
  State<PdfViewerScreen> createState() => _PdfViewerScreenState();
}

class _PdfViewerScreenState extends State<PdfViewerScreen> {
  late final _controller = PdfControllerPinch(
    document: PdfDocument.openData(widget.bytesFuture),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.fileName, overflow: TextOverflow.ellipsis),
      ),
      body: PdfViewPinch(
        controller: _controller,
        builders: PdfViewPinchBuilders<DefaultBuilderOptions>(
          options: const DefaultBuilderOptions(),
          documentLoaderBuilder: (_) =>
              const Center(child: CircularProgressIndicator()),
          errorBuilder: (_, error) => Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text('PDF를 열 수 없습니다: $error', textAlign: TextAlign.center),
            ),
          ),
        ),
      ),
    );
  }
}
