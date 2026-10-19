import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:image/image.dart' as img;

import 'app_settings.dart';
import 'memory_file.dart';
import 'network_type.dart';

/// 휴대폰 데이터일 때 사진을 원본 대신 **일반 화질**로 보낸다(카카오톡의 "사진 화질: 일반"과 같은 생각 — 환경설정
/// AppSettings.cellularPhotoNormalQuality, 기본 켬). 긴 변을 [kNormalPhotoMaxSide]px까지 줄이고 JPEG([kNormalPhotoQuality])로
/// 다시 담는다. 카메라 사진의 회전(EXIF)은 그림에 반영하고, 위치(GPS) 같은 EXIF 정보는 다시 담을 때 빠진다.
///
/// 채팅·댓글 입력칸, 게시글 편집, 다른 앱에서 공유, 문의하기가 사진을 올리기 직전에 [photoForUpload]를 부른다. Wi-Fi이거나
/// 연결 종류를 모르면(PC 등), 이미 작은 사진([kNormalPhotoMinBytes] 아래)·움직이는 GIF·줄여도 작아지지 않는 사진은 원본 그대로.
/// 투명한 부분이 있는 PNG는 JPEG로 바꾸면 바탕이 검게 되므로 PNG로 두고 크기만 줄인다. 사진첩·투표·할 일의 첨부는 원본 그대로
/// 둔다(자료로 남기는 곳이라).

/// 일반 화질의 긴 변(px).
const kNormalPhotoMaxSide = 2048;

/// 일반 화질 JPEG 품질.
const kNormalPhotoQuality = 80;

/// 이보다 작은 사진은 줄이지 않는다(이미 충분히 작다).
const kNormalPhotoMinBytes = 500 * 1024;

class _Request {
  final Uint8List bytes;
  final String name;
  const _Request(this.bytes, this.name);
}

String _withExtension(String name, String ext) {
  final dot = name.lastIndexOf('.');
  final base = dot > 0 ? name.substring(0, dot) : name;
  return '$base.$ext';
}

/// 일반 화질로 줄인 바이트와 새 이름 — 줄일 까닭이 없으면 null(원본 그대로 보낸다).
({Uint8List bytes, String name})? _reduceSync(_Request req) {
  final lower = req.name.toLowerCase();
  if (req.bytes.length < kNormalPhotoMinBytes) return null;
  if (lower.endsWith('.gif')) return null; // 움직이는 GIF는 첫 장만 남게 되므로.
  final decoded = img.decodeImage(req.bytes);
  if (decoded == null) return null;
  final oriented = img.bakeOrientation(decoded);
  final longest = oriented.width >= oriented.height
      ? oriented.width
      : oriented.height;
  final resized = longest > kNormalPhotoMaxSide
      ? (oriented.width >= oriented.height
            ? img.copyResize(oriented, width: kNormalPhotoMaxSide)
            : img.copyResize(oriented, height: kNormalPhotoMaxSide))
      : oriented;
  final keepPng = lower.endsWith('.png') && oriented.hasAlpha;
  if (keepPng && identical(resized, oriented)) {
    return null; // 투명 PNG는 크기만 줄이는데, 이미 작다.
  }
  final out = keepPng
      ? img.encodePng(resized)
      : img.encodeJpg(resized, quality: kNormalPhotoQuality);
  if (out.length >= req.bytes.length) return null;
  return (
    bytes: Uint8List.fromList(out),
    name: keepPng ? req.name : _withExtension(req.name, 'jpg'),
  );
}

/// [bytes]([name])를 일반 화질로 줄인다 — 무거운 일은 따로(compute). 줄일 까닭이 없거나 실패하면 null.
@visibleForTesting
Future<({Uint8List bytes, String name})?> normalQualityPhoto(
  Uint8List bytes,
  String name,
) async {
  try {
    return await compute(_reduceSync, _Request(bytes, name));
  } catch (_) {
    return null;
  }
}

/// 보낼 사진 — 휴대폰 데이터이고 환경설정이 켜져 있으면 일반 화질로 줄인 파일과 바이트, 아니면 null(원본 그대로).
Future<({XFile file, Uint8List bytes})?> photoForUpload(
  AppSettings settings,
  XFile file,
  Uint8List bytes, {
  String? name,
}) async {
  if (!settings.cellularPhotoNormalQuality) return null;
  if (!await isOnCellularData()) return null;
  final given = name ?? file.name;
  final reduced = await normalQualityPhoto(
    bytes,
    given.isEmpty ? 'photo.jpg' : given,
  );
  if (reduced == null) return null;
  return (
    file: bytesAsFile(
      reduced.bytes,
      reduced.name,
      mimeType: reduced.name.toLowerCase().endsWith('.png')
          ? 'image/png'
          : 'image/jpeg',
    ),
    bytes: reduced.bytes,
  );
}
