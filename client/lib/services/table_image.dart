import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'table_paste.dart';

/// 표를 그리는 모양 — 글자 크기·여백·선 굵기와 색. 흰 바탕에 얇은 테두리만 있는 단순한 표다(엑셀식 A·B·C / 1·2·3
/// 머리글 칸이 없다). 머리글 `<th>`가 있으면 첫 행만 옅은 바탕에 굵게 그린다.
class TableImageStyle {
  final double fontSize;
  final double cellPaddingX;
  final double cellPaddingY;
  final double minColumnWidth;
  final double maxColumnWidth;
  final int maxLinesPerCell;
  final Color background;
  final Color gridColor;
  final Color textColor;
  final Color headerBackground;

  /// 그림의 긴 변이 이 픽셀을 넘지 않게 배율을 줄인다(GPU 텍스처 한도).
  final double maxPixelSide;

  /// 기본 배율(선명하게 2배) — 큰 표는 [maxPixelSide]에 맞춰 줄어든다.
  final double pixelRatio;

  const TableImageStyle({
    this.fontSize = 14,
    this.cellPaddingX = 10,
    this.cellPaddingY = 6,
    this.minColumnWidth = 44,
    this.maxColumnWidth = 360,
    this.maxLinesPerCell = 6,
    this.background = const Color(0xFFFFFFFF),
    this.gridColor = const Color(0xFFD0D5DD),
    this.textColor = const Color(0xFF1F2328),
    this.headerBackground = const Color(0xFFF2F4F7),
    this.maxPixelSide = 8192,
    this.pixelRatio = 2,
  });
}

/// 그리기 전에 계산한 모양 — 열 너비·행 높이와 칸마다 배치된 글자. 그림 크기 계산을 따로 시험할 수 있게 분리했다.
class TableImageLayout {
  final List<double> columnWidths;
  final List<double> rowHeights;
  final List<List<TextPainter>> painters;
  const TableImageLayout({
    required this.columnWidths,
    required this.rowHeights,
    required this.painters,
  });

  double get width => columnWidths.fold(0, (a, b) => a + b);
  double get height => rowHeights.fold(0, (a, b) => a + b);
}

const _fontFallback = <String>[
  'Malgun Gothic',
  'NanumBarunGothicYetHangul',
  'Noto Sans KR',
  'Apple SD Gothic Neo',
  'Segoe UI',
];

TextPainter _painter(String text, TableImageStyle style, {bool bold = false}) {
  return TextPainter(
    text: TextSpan(
      text: text,
      style: TextStyle(
        color: style.textColor,
        fontSize: style.fontSize,
        fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
        fontFamily: _fontFallback.first,
        fontFamilyFallback: _fontFallback.sublist(1),
        height: 1.35,
      ),
    ),
    textDirection: TextDirection.ltr,
    maxLines: style.maxLinesPerCell,
    ellipsis: '…',
  );
}

/// [table]의 열 너비(글자 길이에 맞추되 [TableImageStyle.minColumnWidth]~[TableImageStyle.maxColumnWidth])와 행 높이를
/// 계산한다. 한 칸이 너무 길면 열 너비에서 줄바꿈하고 [TableImageStyle.maxLinesPerCell]줄을 넘으면 …로 줄인다.
TableImageLayout layoutTable(
  PastedTable table, {
  TableImageStyle style = const TableImageStyle(),
}) {
  final rows = table.cells;
  final columnCount = table.columnCount;
  final painters = <List<TextPainter>>[
    for (var r = 0; r < rows.length; r++)
      [
        for (var c = 0; c < columnCount; c++)
          _painter(rows[r][c], style, bold: table.hasHeader && r == 0),
      ],
  ];
  final padX = style.cellPaddingX * 2;
  final columnWidths = List<double>.filled(columnCount, style.minColumnWidth);
  for (var c = 0; c < columnCount; c++) {
    var widest = 0.0;
    for (final row in painters) {
      // 줄바꿈 없이 한 줄로 폈을 때의 너비 — 가장 긴 칸이 열 너비를 정한다.
      row[c].layout();
      widest = math.max(widest, row[c].width);
    }
    columnWidths[c] = (widest + padX).clamp(
      style.minColumnWidth,
      style.maxColumnWidth,
    );
  }
  final rowHeights = <double>[];
  for (final row in painters) {
    var tallest = 0.0;
    for (var c = 0; c < columnCount; c++) {
      row[c].layout(maxWidth: columnWidths[c] - padX);
      tallest = math.max(tallest, row[c].height);
    }
    rowHeights.add(tallest + style.cellPaddingY * 2);
  }
  return TableImageLayout(
    columnWidths: columnWidths,
    rowHeights: rowHeights,
    painters: painters,
  );
}

/// 그림의 (가로, 세로) 픽셀 크기 — 배율은 [TableImageStyle.pixelRatio]이고, 긴 변이 [TableImageStyle.maxPixelSide]를
/// 넘으면 그만큼 줄인다.
({int width, int height, double ratio}) tableImagePixelSize(
  TableImageLayout layout,
  TableImageStyle style,
) {
  final longest = math.max(layout.width, layout.height);
  final ratio = math.min(style.pixelRatio, style.maxPixelSide / longest);
  return (
    width: math.max(1, (layout.width * ratio).ceil()),
    height: math.max(1, (layout.height * ratio).ceil()),
    ratio: ratio,
  );
}

/// [table]을 PNG로 그린다 — 입력창이 붙여넣은 표를 이미지 첨부로 올릴 때 쓴다. dart:ui 캔버스로 직접 그려서 화면에 위젯을
/// 띄울 필요가 없다. 테스트에서는 실제 이미지 인코딩이 필요하니 `tester.runAsync` 안에서 부른다.
Future<Uint8List> renderTablePng(
  PastedTable table, {
  TableImageStyle style = const TableImageStyle(),
}) async {
  final layout = layoutTable(table, style: style);
  final size = tableImagePixelSize(layout, style);
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.scale(size.ratio);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, layout.width, layout.height),
    Paint()..color = style.background,
  );

  final grid = Paint()
    ..color = style.gridColor
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1;
  var y = 0.0;
  for (var r = 0; r < layout.rowHeights.length; r++) {
    final h = layout.rowHeights[r];
    var x = 0.0;
    for (var c = 0; c < layout.columnWidths.length; c++) {
      final w = layout.columnWidths[c];
      final cell = Rect.fromLTWH(x, y, w, h);
      if (table.hasHeader && r == 0) {
        canvas.drawRect(cell, Paint()..color = style.headerBackground);
      }
      canvas.drawRect(cell.deflate(0.5), grid); // 바깥 테두리가 그림 밖으로 잘리지 않게 반 픽셀 안쪽에 긋는다.
      layout.painters[r][c].paint(
        canvas,
        Offset(x + style.cellPaddingX, y + style.cellPaddingY),
      );
      x += w;
    }
    y += h;
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(size.width, size.height);
  try {
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    if (data == null) throw StateError('표 이미지를 만들지 못했습니다.');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  } finally {
    image.dispose();
    picture.dispose();
    for (final row in layout.painters) {
      for (final p in row) {
        p.dispose();
      }
    }
  }
}
