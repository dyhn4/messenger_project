import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../models/room.dart';
import '../models/todo.dart';
import '../widgets/app_toast.dart';
import 'session.dart';

/// 한 메시지에 담는 첨부 수 — 더 많으면 나눠 보낸다(채팅 입력칸과 같다).
const todoUploadFilesPerMessage = 10;

/// 할 일 더보기(⋯ · •••)의 "파일 업로드" — 파일을 골라 결과물을 올린다.
/// - 할 일에 업로드 경로([Todo.uploadPath])가 있으면 그 폴더로 복사한다(PC에서만 — 그 PC에서 보이는 폴더·공유 폴더). 같은
///   이름이 있으면 `이름_보낸 사람.확장자`로 올린다([uniqueTargetPath]).
/// - 없으면 할 일을 만든 사람에게 1:1 메시지로 보낸다(내가 만든 할 일이거나 만든 사람이 없으면 나와의 대화로).
Future<void> uploadTodoFiles(
  BuildContext context,
  Session session,
  Todo todo,
) async {
  // 알림을 띄울 자리 — 고르는 동안 할 일 화면이 닫혀도 앱 맨 위에 뜨게 먼저 잡아 둔다.
  final overlay = Overlay.of(context, rootOverlay: true);
  void toast(String message) => showAppToastOnOverlay(overlay, message);

  final folder = todo.uploadPath;
  if (folder != null) {
    if (!Platform.isWindows) {
      toast('지정된 업로드 경로로는 PC(Windows)에서만 올릴 수 있습니다.');
      return;
    }
    if (!await Directory(folder).exists()) {
      toast('업로드 경로를 찾을 수 없습니다: $folder');
      return;
    }
  }

  final picked = await FilePicker.pickFiles(
    allowMultiple: true,
    dialogTitle: folder == null ? '보낼 파일 선택' : '업로드할 파일 선택',
  );
  final files = [
    for (final f in picked?.files ?? const <PlatformFile>[])
      if (f.path != null) File(f.path!),
  ];
  if (files.isEmpty) return;

  if (folder != null) {
    final result = await copyFilesToFolder(
      files,
      folder,
      senderName: session.name ?? '',
    );
    toast(
      result.failed == 0
          ? '파일 ${result.copied}개를 업로드 경로에 올렸습니다.'
          : '파일 ${result.copied}개를 올렸고 ${result.failed}개는 올리지 못했습니다.',
    );
    return;
  }

  try {
    final room = await _uploadTargetRoom(session, todo);
    toast('파일 ${files.length}개를 보내는 중입니다...');
    final uploaded = await session.uploadAttachments(files);
    final controller = session.controllerFor(room);
    for (var i = 0; i < uploaded.length; i += todoUploadFilesPerMessage) {
      final end = (i + todoUploadFilesPerMessage).clamp(0, uploaded.length);
      await controller.sendUploadedAttachments(
        uploaded.sublist(i, end),
        caption: i == 0 ? todoUploadCaption(todo) : null,
      );
    }
    final creatorName = todo.creator?.name;
    toast(
      room.isSelf || creatorName == null
          ? '나와의 대화로 파일 ${files.length}개를 보냈습니다.'
          : '$creatorName님에게 파일 ${files.length}개를 메시지로 보냈습니다.',
    );
  } catch (e) {
    toast('파일을 보내지 못했습니다: $e');
  }
}

/// 업로드 경로가 없을 때 파일을 보낼 방 — 만든 사람과의 1:1, 내가 만들었거나 만든 사람이 없으면 나와의 대화.
Future<Room> _uploadTargetRoom(Session session, Todo todo) {
  final creatorId = todo.creator?.id;
  if (creatorId == null || creatorId == session.userId) {
    return session.openSelfChat(teamId: todo.teamId);
  }
  return session.startDm(creatorId, teamId: todo.teamId);
}

/// 메시지로 보낼 때 첫 메시지에 붙는 글.
String todoUploadCaption(Todo todo) => '[할 일] ${todo.title} — 파일을 올렸습니다.';

/// [files]를 [folder]에 복사한다 — 같은 이름이 있으면 보낸 사람 이름을 붙인다([uniqueTargetPath]). 복사한 수와 실패한 수.
Future<({int copied, int failed})> copyFilesToFolder(
  List<File> files,
  String folder, {
  required String senderName,
}) async {
  var copied = 0;
  var failed = 0;
  for (final file in files) {
    try {
      final name = file.uri.pathSegments.last;
      final target = await uniqueTargetPath(folder, name, senderName);
      await file.copy(target);
      copied++;
    } catch (_) {
      failed++;
    }
  }
  return (copied: copied, failed: failed);
}

/// [folder]에 [name]으로 올릴 경로 — 같은 이름이 이미 있으면 `이름_보낸 사람.확장자`(누가 올린 것인지 보이게), 그것도
/// 있으면 `이름_보낸 사람 (1).확장자`, `(2)`… 중 빈 이름. 보낸 사람 이름에 파일 이름으로 못 쓰는 글자(\ / : * ? " < > |)가
/// 있으면 `_`로 바꾸고, 이름이 비었으면 번호만 붙인다.
Future<String> uniqueTargetPath(
  String folder,
  String name,
  String senderName,
) async {
  final sep = Platform.pathSeparator;
  final base = folder.endsWith(sep) ? folder : '$folder$sep';
  var candidate = '$base$name';
  if (!await File(candidate).exists()) return candidate;
  final dot = name.lastIndexOf('.');
  final stem = dot > 0 ? name.substring(0, dot) : name;
  final ext = dot > 0 ? name.substring(dot) : '';
  final sender = senderName.trim().replaceAll(RegExp(r'[\/:*?"<>|]'), '_');
  final named = sender.isEmpty ? stem : '${stem}_$sender';
  if (sender.isNotEmpty) {
    candidate = '$base$named$ext';
    if (!await File(candidate).exists()) return candidate;
  }
  for (var i = 1; ; i++) {
    candidate = '$base$named ($i)$ext';
    if (!await File(candidate).exists()) return candidate;
  }
}
