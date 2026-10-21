import 'package:cross_file/cross_file.dart';

import 'outbox_files_io.dart'
    if (dart.library.js_interop) 'outbox_files_web.dart'
    as impl;
import 'memory_file.dart';
import 'message_outbox.dart';

/// 보내기 대기열이 아직 올리지 못한 첨부를 담아 두는 곳 — 앱은 앱 폴더의 outbox_files/<임시 id>/, 웹은 브라우저의 IndexedDB(앱을
/// 다시 켜도·새로 고쳐도 남는다). 못 담으면 null(부르는 쪽이 예전처럼 실패를 알린다).
Future<List<OutboxFile>?> stashFilesForOutbox(
  String clientId,
  List<({List<int> bytes, String name, String? mimeType, bool isImage})> files,
) => impl.stashFilesForOutbox(clientId, files);

Future<bool> outboxFileExists(String path) => impl.outboxFileExists(path);

/// 담아 둔 첨부를 올릴 파일로(원래 이름·형식으로). 비밀 대화의 것은 메모리의 바이트로([OutboxFile.bytes]). 없어졌으면 null.
Future<XFile?> openOutboxFile(OutboxFile f) async {
  final bytes = f.bytes;
  if (bytes != null) return bytesAsFile(bytes, f.name, mimeType: f.mimeType);
  return impl.openOutboxFile(f);
}

Future<void> deleteOutboxFile(String path) => impl.deleteOutboxFile(path);

/// 그 임시 id의 폴더를 통째로 치운다(다 올렸거나 버렸을 때).
Future<void> deleteOutboxFiles(String clientId) =>
    impl.deleteOutboxFiles(clientId);
