import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import '../models/todo.dart';
import '../widgets/app_toast.dart';
import '../widgets/attachment_widgets.dart'
    show fetchAttachmentBytes, saveAttachment;
import 'app_platform.dart';
import 'download_storage.dart';
import 'session.dart';

/// 할 일 첨부 여러 개를 내려받은 결과.
class TodoDownloadSummary {
  final int saved;
  final int failed;

  /// 저장한 폴더(안드로이드는 공용 Download 아래 폴더) — 없으면 null.
  final String? folder;
  const TodoDownloadSummary({this.saved = 0, this.failed = 0, this.folder});
}

/// 파일 이름에 쓸 수 없는 글자(Windows 기준) — 받은 이름에 섞여 있으면 `_`로 바꾼다.
final _unsafeFileChars = RegExp(r'[\\/:*?"<>|]');

/// 저장할 파일 이름 — 첨부 이름 그대로(못 쓰는 글자만 `_`로). 이름이 없으면 종류에 맞는 확장자로 임시 이름을 만든다.
String todoAttachmentFileName(TodoAttachment attachment, int index) {
  final name = attachment.fileName?.replaceAll(_unsafeFileChars, '_').trim();
  if (name != null && name.isNotEmpty) return name;
  final mime = (attachment.mimeType ?? '').toLowerCase();
  final sub = mime.contains('/') ? mime.split('/').last : '';
  final ext = RegExp(r'^[a-z0-9]{2,4}$').hasMatch(sub)
      ? sub.replaceAll('jpeg', 'jpg')
      : (attachment.isImage ? 'jpg' : 'bin');
  return 'todo_file_${index + 1}.$ext';
}

/// [attachments]를 [folder]에 차례로 저장한다 — 이름이 겹치면 "이름 (1).확장자"로 번호를 붙이고(덮어쓰지 않는다,
/// [writeDownloadFile]), 한 개가 실패해도 나머지는 계속한다. [fetch]는 첨부의 바이트를 받아 오는 함수(서명 링크가
/// 만료됐으면 새로 받아 재시도하는 것까지 맡는다 — 앱에서는 [fetchAttachmentBytes]).
Future<TodoDownloadSummary> saveTodoAttachmentsToFolder({
  required List<TodoAttachment> attachments,
  required String folder,
  required Future<List<int>> Function(TodoAttachment attachment) fetch,
  void Function(int done, int total)? onProgress,
}) async {
  var saved = 0;
  var failed = 0;
  onProgress?.call(0, attachments.length);
  for (var i = 0; i < attachments.length; i++) {
    try {
      final bytes = await fetch(attachments[i]);
      await writeDownloadFile(
        folder: folder,
        fileName: todoAttachmentFileName(attachments[i], i),
        bytes: bytes,
      );
      saved++;
    } catch (_) {
      failed++;
    }
    onProgress?.call(i + 1, attachments.length);
  }
  return TodoDownloadSummary(saved: saved, failed: failed, folder: folder);
}

/// 다 받은 뒤 토스트 문구 — `N개를 다운로드했습니다. (폴더)`, 실패가 있으면 그 수도, 하나도 못 받았으면 실패 안내.
String todoDownloadResultText(TodoDownloadSummary summary) {
  final where = summary.folder == null
      ? ''
      : ' (${displayDownloadPath(summary.folder!)})';
  if (summary.failed == 0) return '${summary.saved}개를 다운로드했습니다.$where';
  if (summary.saved == 0) return '다운로드하지 못했습니다.';
  return '${summary.saved}개를 다운로드했습니다. ${summary.failed}개는 실패했습니다.$where';
}

bool get _isMobile => AppPlatform.isAndroid || AppPlatform.isIOS;

/// 할 일의 첨부를 전부 내려받는다(상세 ⋯ 메뉴의 "파일 다운로드") — 앨범 내려받기(album_download.dart)와 같은 방식이다.
/// PC는 폴더 선택 대화상자로 받은 폴더에 차례로 저장하고(메시지의 "전체 다운로드"처럼 "저장 위치 안 물어보기"가 켜져 있으면
/// 설정 폴더에 바로), 안드로이드는 파일 하나 다운로드와 같은 방식(공용 Download/TangoTalk)으로 첨부마다 저장한다. 끝나면
/// 토스트로 알리고, "다운로드 완료 시 폴더 열기"가 켜져 있으면 저장한 폴더를 연다.
///
/// [pickFolder]·[fetch]는 테스트가 폴더 선택 창과 내려받기를 대신 끼우는 자리.
Future<void> downloadTodoAttachments(
  BuildContext context,
  Session session,
  Todo todo, {
  void Function(int done, int total)? onProgress,
  Future<String?> Function()? pickFolder,
  Future<List<int>> Function(TodoAttachment attachment)? fetch,
}) async {
  final attachments = todo.attachments;
  if (attachments.isEmpty) return;
  // 끝난 알림은 앱 맨 위 Overlay(창 전체 기준)에 — PC 할 일 패널 안 상세의 가장 가까운 Overlay는 패널의 중첩
  // Navigator 것(폭 420)이라 창 폭으로 자리를 잡는 토스트가 맞지 않는다.
  final overlay = Overlay.of(context, rootOverlay: true);
  final settings = session.settings;

  TodoDownloadSummary summary;
  // 웹은 폴더를 고를 수 없어 모바일처럼 하나씩 받는다(브라우저 다운로드).
  if (_isMobile || kIsWeb) {
    var saved = 0;
    var failed = 0;
    onProgress?.call(0, attachments.length);
    for (var i = 0; i < attachments.length; i++) {
      try {
        final path = await saveAttachment(
          session: session,
          url: session.resolveUrl(attachments[i].fileUrl),
          fileName: todoAttachmentFileName(attachments[i], i),
        );
        path == null ? failed++ : saved++;
      } catch (_) {
        failed++;
      }
      onProgress?.call(i + 1, attachments.length);
    }
    summary = TodoDownloadSummary(
      saved: saved,
      failed: failed,
      folder: kIsWeb ? null : await androidDownloadFolder(),
    );
  } else {
    final initial = settings.downloadFolder;
    final folder = settings.savesWithoutAsking
        ? initial
        : await (pickFolder ??
              () => FilePicker.getDirectoryPath(
                dialogTitle: '저장할 폴더 선택',
                initialDirectory: initial.isEmpty ? null : initial,
              ))();
    if (folder == null) return;
    summary = await saveTodoAttachmentsToFolder(
      attachments: attachments,
      folder: folder,
      fetch:
          fetch ??
          (a) => fetchAttachmentBytes(
            session: session,
            url: session.resolveUrl(a.fileUrl),
          ),
      onProgress: onProgress,
    );
  }

  showAppToastOnOverlay(
    overlay,
    todoDownloadResultText(summary),
    duration: const Duration(seconds: 4),
  );
  final folder = summary.folder;
  if (summary.saved > 0 && settings.openFolderAfterDownload && folder != null) {
    await _openFolder(folder);
  }
}

/// 저장한 폴더를 탐색기로 연다(Windows만) — 설정의 openDownloadFolder는 설정 폴더만 열어서, 다른 폴더를 골랐을 때도
/// 받은 파일이 있는 곳이 열리게 직접 연다. 안드로이드는 폴더를 열지 않는다(토스트에 경로가 있다).
Future<void> _openFolder(String folder) async {
  if (!AppPlatform.isWindows) return;
  try {
    await Process.start('explorer.exe', [folder]);
  } catch (_) {
    // 못 열어도 파일은 이미 저장돼 있다.
  }
}
