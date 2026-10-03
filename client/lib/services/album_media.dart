import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

import '../models/album.dart';

// 앨범에 올릴 파일을 알아보고 준비하는 조각들 — 확장자로 종류(이미지·GIF·영상)와 mimeType을 정하고, 이미지는
// 격자용 축소 썸네일과 가로·세로를 만든다. 영상은 프레임을 뽑는 라이브러리가 없어서 썸네일·길이 없이 올린다
// (격자에는 재생 아이콘이 얹힌 어두운 칸으로 보인다).

const _imageMimes = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.bmp': 'image/bmp',
  '.heic': 'image/heic',
  '.heif': 'image/heif',
};

const _videoMimes = {
  '.mp4': 'video/mp4',
  '.m4v': 'video/x-m4v',
  '.mov': 'video/quicktime',
  '.avi': 'video/x-msvideo',
  '.mkv': 'video/x-matroska',
  '.webm': 'video/webm',
  '.wmv': 'video/x-ms-wmv',
  '.3gp': 'video/3gpp',
  '.mpg': 'video/mpeg',
  '.mpeg': 'video/mpeg',
};

/// 파일 선택 대화상자에 넘길 확장자(점 없이).
final albumPickerExtensions = [
  for (final e in [..._imageMimes.keys, ..._videoMimes.keys]) e.substring(1),
];

String _extOf(String path) {
  final name = path.split(RegExp(r'[\\/]')).last.toLowerCase();
  final dot = name.lastIndexOf('.');
  return dot < 0 ? '' : name.substring(dot);
}

/// 경로의 확장자로 본 mimeType — 이미지·영상이 아니면 null(앨범에 못 올린다).
String? albumMimeForPath(String path) {
  final ext = _extOf(path);
  return _imageMimes[ext] ?? _videoMimes[ext];
}

AlbumItemKind? albumKindForMime(String? mime) {
  final m = (mime ?? '').toLowerCase();
  if (m.startsWith('image/')) return AlbumItemKind.image;
  if (m.startsWith('video/')) return AlbumItemKind.video;
  return null;
}

String albumFileName(String path) => path.split(RegExp(r'[\\/]')).last;

/// 이미지 하나를 준비한 결과 — 격자용 썸네일(JPEG)과 원본의 가로·세로.
class AlbumImagePrep {
  final Uint8List? thumbnail;
  final int? width;
  final int? height;
  const AlbumImagePrep({this.thumbnail, this.width, this.height});
}

/// 파일을 올리기 전에 준비한다 — 이미지는 썸네일과 크기, 영상은 없음. 디코딩이 안 되는 형식(HEIC 등)은 빈 결과.
typedef AlbumMediaPreparer =
    Future<AlbumImagePrep> Function(File file, AlbumItemKind kind);

const _thumbMaxSide = 480;

AlbumImagePrep _prepareSync(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return const AlbumImagePrep();
  final oriented = img.bakeOrientation(decoded);
  final wide = oriented.width >= oriented.height;
  final longSide = wide ? oriented.width : oriented.height;
  final resized = longSide <= _thumbMaxSide
      ? oriented
      : (wide
            ? img.copyResize(oriented, width: _thumbMaxSide)
            : img.copyResize(oriented, height: _thumbMaxSide));
  return AlbumImagePrep(
    thumbnail: Uint8List.fromList(img.encodeJpg(resized, quality: 72)),
    width: oriented.width,
    height: oriented.height,
  );
}

Future<AlbumImagePrep> defaultAlbumMediaPreparer(
  File file,
  AlbumItemKind kind,
) async {
  if (kind != AlbumItemKind.image) return const AlbumImagePrep();
  try {
    return await compute(_prepareSync, await file.readAsBytes());
  } catch (_) {
    return const AlbumImagePrep();
  }
}
