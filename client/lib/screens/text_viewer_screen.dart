import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../l10n/tr.dart';

/// txt 첨부 인앱 뷰어. 채팅 버블에서 .txt 파일명을 탭하면 엽니다 — PdfViewerScreen과 같은
/// 이유로 [bytesFuture]를 받는다(비밀 대화는 이 화면을 열 때 복호화).
class TextViewerScreen extends StatelessWidget {
  final String fileName;
  final Future<Uint8List> bytesFuture;
  const TextViewerScreen({
    super.key,
    required this.fileName,
    required this.bytesFuture,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(fileName, overflow: TextOverflow.ellipsis)),
      body: FutureBuilder<Uint8List>(
        future: bytesFuture,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(
              child: Text(
                tr('파일을 열 수 없습니다: {snapshot.error}', {
                  'snapshot.error': snapshot.error,
                }),
              ),
            );
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          // 이 프로젝트는 전반적으로 UTF-8 기준이라(서버/클라이언트 텍스트 처리 전부 UTF-8),
          // 다른 인코딩(EUC-KR 등)의 txt는 깨져 보일 수 있다 — 지금은 그 변환까지는 하지 않는다.
          final text = utf8.decode(snapshot.data!, allowMalformed: true);
          return SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: SelectableText(
              text,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            ),
          );
        },
      ),
    );
  }
}
