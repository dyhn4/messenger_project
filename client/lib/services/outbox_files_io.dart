import 'dart:io';

import 'package:cross_file/cross_file.dart';
import 'package:path_provider/path_provider.dart';

import 'message_outbox.dart';

/// 시험이 폴더를 바꾸는 자리.
Future<Directory> Function() outboxFilesBaseDir = () async =>
    Directory('${(await getApplicationSupportDirectory()).path}/outbox_files');

String _safe(String raw) => raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

/// 디스크 이름으로 쓸 수 있게 — 경로 구분자·Windows가 막는 글자·제어 문자만 _로(한국어 이름은 그대로).
String _fileNameOf(String name) {
  final cleaned = name
      .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
      .replaceAll(RegExp(r'[. ]+$'), '');
  return cleaned.isEmpty || cleaned == '.' || cleaned == '..'
      ? 'file'
      : cleaned;
}

Future<List<OutboxFile>?> stashFilesForOutbox(
  String clientId,
  List<({List<int> bytes, String name, String? mimeType, bool isImage})> files,
) async {
  try {
    final dir = Directory(
      '${(await outboxFilesBaseDir()).path}/${_safe(clientId)}',
    );
    await dir.create(recursive: true);
    final out = <OutboxFile>[];
    for (final (i, f) in files.indexed) {
      // 번호 폴더 아래 원래 이름으로 — 네이티브 XFile은 이름을 따로 받지 않고 경로의 마지막 조각을 올릴 때 이름으로 쓴다(예전엔
      // `0.bin`으로 담아 서버에도 그 이름으로 올라갔다).
      final sub = Directory('${dir.path}/$i');
      await sub.create(recursive: true);
      // 마지막 조각은 이 기기의 구분자로(XFile이 Platform.pathSeparator로 잘라 이름을 얻는다 — Windows는 '\').
      final file = File(
        '${sub.path}${Platform.pathSeparator}${_fileNameOf(f.name)}',
      );
      await file.writeAsBytes(f.bytes, flush: true);
      out.add(
        OutboxFile(
          path: file.path,
          name: f.name,
          size: f.bytes.length,
          mimeType: f.mimeType,
          isImage: f.isImage,
        ),
      );
    }
    return out;
  } catch (_) {
    return null;
  }
}

Future<bool> outboxFileExists(String path) => File(path).exists();

Future<XFile?> openOutboxFile(OutboxFile f) async =>
    await File(f.path).exists() ? XFile(f.path, mimeType: f.mimeType) : null;

Future<void> deleteOutboxFile(String path) async {
  try {
    await File(path).delete();
  } catch (_) {}
}

Future<void> deleteOutboxFiles(String clientId) async {
  try {
    final dir = Directory(
      '${(await outboxFilesBaseDir()).path}/${_safe(clientId)}',
    );
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {}
}
