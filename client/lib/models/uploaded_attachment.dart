import 'message.dart';

/// 첨부 업로드가 끝난 뒤(암호화 여부와 무관하게) 실제 메시지/댓글 전송에 필요한 결과.
/// ChatInputBar/CommentInputBar가 첨부한 즉시 RoomChatController.uploadAttachment로 이 값을
/// 만들어두고, 사용자가 "보내기"를 누르면 sendUploadedAttachment/postUploadedCommentAttachment에
/// 그대로 넘긴다 — 그때는 이미 올라가 있는 파일이라 다시 업로드하지 않는다.
/// (예약 메시지처럼 서비스 계층 밖에서도 쓰여서 모델로 두고, room_chat_controller.dart가 다시 내보낸다.)
class UploadedAttachment {
  final bool isImage;
  final String url;
  final String fileName;
  final int size;
  final String? mimeType;
  final String? thumbnailUrl;

  /// 비밀 대화일 때만 채워짐 — [url]이 가리키는 바이트가 이미 암호화됐다는 뜻.
  final String? attachmentKey;
  final String? attachmentNonce;
  final String? thumbnailKey;
  final String? thumbnailNonce;

  UploadedAttachment({
    required this.isImage,
    required this.url,
    required this.fileName,
    required this.size,
    this.mimeType,
    this.thumbnailUrl,
    this.attachmentKey,
    this.attachmentNonce,
    this.thumbnailKey,
    this.thumbnailNonce,
  });

  /// 이미 서버에 있는 첨부(예약 메시지를 고칠 때 등)를 다시 보낼 모양으로 — 서명된 /files/ 링크여도
  /// 서버가 원본 경로로 되돌려 저장한다(server/src/upload.js의 resolveRawUrl).
  factory UploadedAttachment.fromMessageAttachment(MessageAttachment a) =>
      UploadedAttachment(
        isImage: a.isImage,
        url: a.fileUrl,
        fileName: a.fileName ?? '',
        size: a.fileSize ?? 0,
        mimeType: a.mimeType,
        thumbnailUrl: a.thumbnailUrl,
      );

  /// message:send의 attachments 한 칸 — 여러 장을 한 말풍선으로 보낼 때(sendUploadedAttachments)와
  /// 보드 게시글(sendPost), 예약 메시지가 같은 모양을 쓴다.
  Map<String, dynamic> toPayload() => {
    'kind': isImage ? 'image' : 'file',
    'fileUrl': url,
    'fileName': fileName,
    'fileSize': size,
    'mimeType': ?mimeType,
    'thumbnailUrl': ?thumbnailUrl,
  };
}
