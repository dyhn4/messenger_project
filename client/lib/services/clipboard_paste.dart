import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import 'app_platform.dart';
import 'table_paste.dart';

/// 붙여넣는 순간의 클립보드 — 이미지(엑셀은 표를 복사하면 비트맵도 함께 올린다)·글자·HTML(Windows만 읽을 수 있다).
class ClipboardSnapshot {
  final Uint8List? image;
  final String? text;
  final String? html;
  const ClipboardSnapshot({this.image, this.text, this.html});

  bool get hasImage => image != null && image!.isNotEmpty;
}

typedef ClipboardReader = Future<ClipboardSnapshot> Function();

/// 시스템 클립보드를 읽는다 — 이미지와 HTML은 pasteboard 플러그인(이미지는 모든 플랫폼, HTML은 Windows), 글자는 Flutter
/// 기본 클립보드. 읽다가 실패한 조각은 없는 것으로 본다(붙여넣기가 막히면 안 된다).
Future<ClipboardSnapshot> readSystemClipboard() async {
  Uint8List? image;
  try {
    image = await Pasteboard.image;
  } catch (_) {}
  String? text;
  try {
    text = (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  } catch (_) {}
  String? html;
  if (AppPlatform.isWindows) {
    try {
      html = await Pasteboard.html;
    } catch (_) {}
  }
  return ClipboardSnapshot(image: image, text: text, html: html);
}

/// Ctrl+V를 어떻게 처리할지 — 입력칸(chat_input_bar.dart)이 이 결정대로 움직인다.
sealed class PasteDecision {
  const PasteDecision();
}

/// 평소처럼 글자를 붙여넣는다(표도 이미지도 아님).
class PasteAsText extends PasteDecision {
  const PasteAsText();
}

/// 클립보드의 이미지를 업로드 미리보기로 올린다 — 글자는 붙이지 않는다(엑셀 표: 글자와 비트맵이 함께 있을 때).
class PasteAsImage extends PasteDecision {
  final Uint8List bytes;
  const PasteAsImage(this.bytes);
}

/// 이미지를 올리고 글자도 그대로 붙여넣는다 — 표가 아닌 이미지+글자(웹에서 복사한 이미지와 설명 등)의 예전 동작.
class PasteAsImageAndText extends PasteDecision {
  final Uint8List bytes;
  const PasteAsImageAndText(this.bytes);
}

/// 탭 텍스트·HTML 표를 이미지로 그려 업로드 미리보기로 올린다(클립보드에 이미지는 없을 때).
class PasteAsTable extends PasteDecision {
  final PastedTable table;
  const PasteAsTable(this.table);
}

/// 클립보드를 보고 Ctrl+V 처리 방식을 정한다(Ctrl+Shift+V는 이 함수를 거치지 않고 언제나 글자 붙여넣기다).
///
///  * 이미지가 있고 글자·HTML이 표 모양 → [PasteAsImage] (잔디: 표를 붙여넣으면 파일 업로드 창이 뜬다. 글자는 안 붙인다)
///  * 이미지만 있거나, 표가 아닌 글자가 함께 있다 → [PasteAsImageAndText] (예전 동작 그대로)
///  * 이미지가 없고 2×2 이상의 탭 텍스트·HTML 표(최대 100행×30열) → [PasteAsTable]
///  * 그 밖(한 줄·한 열, 탭 없는 글, 너무 큰 표) → [PasteAsText]
PasteDecision decidePaste(ClipboardSnapshot clipboard) {
  final image = clipboard.image;
  if (clipboard.hasImage && image != null) {
    final tabular = clipboardLooksTabular(
      text: clipboard.text,
      html: clipboard.html,
    );
    return tabular ? PasteAsImage(image) : PasteAsImageAndText(image);
  }
  final table = detectPastedTable(text: clipboard.text, html: clipboard.html);
  if (table != null) return PasteAsTable(table);
  return const PasteAsText();
}
