import 'message_outbox.dart';

Future<List<OutboxFile>?> stashFilesForOutbox(
  String clientId,
  List<({List<int> bytes, String name, String? mimeType, bool isImage})> files,
) async => null;

Future<bool> outboxFileExists(String path) async => false;

Future<void> deleteOutboxFile(String path) async {}

Future<void> deleteOutboxFiles(String clientId) async {}
