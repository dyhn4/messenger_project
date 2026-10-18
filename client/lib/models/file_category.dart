import 'package:flutter/material.dart';
import '../l10n/tr.dart';

/// 파일 형식 — 파일 패널의 "파일 ⌄" 메뉴와 검색 패널 "파일" 탭의 꺽쇠 메뉴가 같이 쓴다.
/// 서버(server/src/fileKinds.js)의 분류와 이름이 정확히 같아야 한다([apiValue]).
enum FileCategory {
  all,
  image,
  document,
  pdf,
  excel,
  powerpoint,
  video,
  audio,
  archive,
  other,
}

extension FileCategoryInfo on FileCategory {
  /// 메뉴에 보이는 이름.
  String get label => switch (this) {
    FileCategory.all => tr('전체 파일'),
    FileCategory.image => tr('이미지'),
    FileCategory.document => tr('문서'),
    FileCategory.pdf => 'PDF',
    FileCategory.excel => tr('엑셀'),
    FileCategory.powerpoint => tr('파워포인트'),
    FileCategory.video => tr('동영상'),
    FileCategory.audio => tr('오디오'),
    FileCategory.archive => tr('압축 파일'),
    FileCategory.other => tr('기타'),
  };

  /// 탭/단추에 보이는 이름 — 고른 형식이 없으면(전체) 그냥 "파일".
  String get buttonLabel => this == FileCategory.all ? tr('파일') : label;

  IconData get icon => switch (this) {
    FileCategory.all => Icons.insert_drive_file_outlined,
    FileCategory.image => Icons.image_outlined,
    FileCategory.document => Icons.description_outlined,
    FileCategory.pdf => Icons.picture_as_pdf_outlined,
    FileCategory.excel => Icons.grid_on_outlined,
    FileCategory.powerpoint => Icons.slideshow_outlined,
    FileCategory.video => Icons.videocam_outlined,
    FileCategory.audio => Icons.audiotrack_outlined,
    FileCategory.archive => Icons.folder_zip_outlined,
    FileCategory.other => Icons.attach_file,
  };

  /// 서버에 보내는 값 — 전체는 안 보낸다.
  String? get apiValue => this == FileCategory.all ? null : name;
}
