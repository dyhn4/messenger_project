import '../data/stickers.dart';
import '../models/message.dart';
import '../l10n/tr.dart';

/// 메시지 내용을 한 줄 미리보기로 요약한다 — 방 목록 미리보기(session.dart의
/// _updateRoomPreview), 메시지 공유 인용문(message_share_screen.dart)에서 공용으로 쓴다.
String formatMessagePreview({
  required MessageType type,
  String? text,
  String? fileName,
}) {
  return switch (type) {
    MessageType.text => text ?? '',
    MessageType.image => tr('사진을 보냈습니다'),
    MessageType.file =>
      fileName != null
          ? tr('{fileName} 파일을 보냈습니다', {'fileName': fileName})
          : tr('파일을 보냈습니다'),
    MessageType.sticker => stickerPreviewText(text),
    MessageType.system || MessageType.comment => text ?? '',
  };
}
