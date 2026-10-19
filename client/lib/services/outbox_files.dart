import 'outbox_files_io.dart'
    if (dart.library.js_interop) 'outbox_files_web.dart'
    as impl;
import 'message_outbox.dart';

/// 보내기 대기열이 아직 올리지 못한 첨부를 담아 두는 곳 — 앱 폴더의 outbox_files/<임시 id>/(앱을 다시 켜도 남는다). 웹은 폴더가 없어
/// 담지 않는다(null — 부르는 쪽이 예전처럼 실패를 알린다).
Future<List<OutboxFile>?> stashFilesForOutbox(
  String clientId,
  List<({List<int> bytes, String name, String? mimeType, bool isImage})> files,
) => impl.stashFilesForOutbox(clientId, files);

Future<bool> outboxFileExists(String path) => impl.outboxFileExists(path);

Future<void> deleteOutboxFile(String path) => impl.deleteOutboxFile(path);

/// 그 임시 id의 폴더를 통째로 치운다(다 올렸거나 버렸을 때).
Future<void> deleteOutboxFiles(String clientId) =>
    impl.deleteOutboxFiles(clientId);
