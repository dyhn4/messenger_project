import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

/// 메모리의 바이트를 [name]이라는 파일처럼 올리거나 넘길 때 쓰는 XFile(붙여넣은 그림, 썸네일,
/// 비밀 대화 암호문 등 — 디스크에 임시 파일을 만들지 않는다).
///
/// `XFile.fromData`는 네이티브에서 `name`을 무시하고 `path`의 마지막 조각을 이름으로 쓰고, 웹에서는
/// 반대로 `path`를 무시하고 `name`을 쓴다 — 그래서 둘 다 같은 이름을 준다. 네이티브에서 이 가짜
/// 경로는 이름으로만 쓰이고, 내용은 늘 [bytes]에서 읽는다.
XFile bytesAsFile(Uint8List bytes, String name, {String? mimeType}) =>
    XFile.fromData(bytes, name: name, path: name, mimeType: mimeType);
