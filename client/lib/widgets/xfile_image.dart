import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// 올리기 전 첨부(XFile)의 미리보기 그림 — `Image.file`은 경로가 있어야 해서 웹(브라우저가 준
/// 바이트)과 붙여넣은 그림(메모리 파일)을 못 그린다. PC·안드로이드에서 디스크에 있는 파일은 예전처럼
/// `Image.file`로 그리고(큰 원본을 통째로 읽지 않게), 그 밖에는 한 번 읽은 바이트로 그린다.
class XFileImage extends StatefulWidget {
  const XFileImage(
    this.file, {
    super.key,
    this.width,
    this.height,
    this.fit,
    this.cacheWidth,
    this.errorBuilder,
  });

  final XFile file;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final int? cacheWidth;
  final ImageErrorWidgetBuilder? errorBuilder;

  @override
  State<XFileImage> createState() => _XFileImageState();
}

class _XFileImageState extends State<XFileImage> {
  File? _diskFile;
  Future<Uint8List>? _bytes;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(XFileImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file != widget.file) _resolve();
  }

  void _resolve() {
    final path = widget.file.path;
    final onDisk = !kIsWeb && path.isNotEmpty && File(path).existsSync();
    _diskFile = onDisk ? File(path) : null;
    _bytes = onDisk ? null : widget.file.readAsBytes();
  }

  @override
  Widget build(BuildContext context) {
    final disk = _diskFile;
    if (disk != null) {
      return Image.file(
        disk,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        cacheWidth: widget.cacheWidth,
        errorBuilder: widget.errorBuilder,
      );
    }
    return FutureBuilder<Uint8List>(
      future: _bytes,
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes == null) {
          if (snap.hasError && widget.errorBuilder != null) {
            return widget.errorBuilder!(context, snap.error!, snap.stackTrace);
          }
          return SizedBox(width: widget.width, height: widget.height);
        }
        return Image.memory(
          bytes,
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          cacheWidth: widget.cacheWidth,
          errorBuilder: widget.errorBuilder,
        );
      },
    );
  }
}
