import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'message_outbox.dart';

/// 시험이 폴더를 바꾸는 자리.
Future<Directory> Function() outboxFilesBaseDir = () async =>
    Directory('${(await getApplicationSupportDirectory()).path}/outbox_files');

String _safe(String raw) => raw.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

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
      // 이름은 올릴 때 원래 이름으로 보내므로(OutboxFile.name), 디스크 이름은 번호만.
      final file = File('${dir.path}/$i.bin');
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
