import 'package:flutter/widgets.dart' show StringCharacters;

import 'album.dart' show SharedAlbum;
import 'comment.dart';
import 'mention.dart';
import 'poll.dart';
import 'text_format.dart';

/// 메시지에 들어있는 링크의 오픈그래프 미리보기(server/src/linkPreview.js) — 메시지 전송
/// 직후엔 없다가(서버가 백그라운드로 긁어옴) 나중에 message:linkPreview로 채워질 수 있어서
/// Message.linkPreview 필드 자체가 non-final이다.
class LinkPreview {
  final String url;
  final String? title;
  final String? description;
  final String? imageUrl;
  final String? siteName;
  const LinkPreview({
    required this.url,
    this.title,
    this.description,
    this.imageUrl,
    this.siteName,
  });

  factory LinkPreview.fromJson(Map<String, dynamic> json) => LinkPreview(
    url: json['url'] as String,
    title: json['title'] as String?,
    description: json['description'] as String?,
    imageUrl: json['imageUrl'] as String?,
    siteName: json['siteName'] as String?,
  );
}

/// [comment]는 서버가 보내는 실제 메시지 타입이 아니라, 댓글 하나를 채팅 타임라인 안에 그 댓글이
/// 달린 시각 위치에 끼워 넣기 위한 클라이언트 전용 합성(synthetic) 항목이다 — Message.commentEntry로만
/// 만들어지고, 서버 JSON의 type 문자열로는 절대 나오지 않는다(_typeFromString은 이 값을 모른다).
enum MessageType { text, image, file, sticker, system, comment }

/// 프로젝트 자동화의 "채팅방 알림"이 보내는 메시지의 보낸 사람 이름(server/src/projectAutomation.js).
const automationSenderName = '자동화';

/// 보드 뷰 게시글(type 'post') 제목·본문 최대 길이와 첨부 개수 — 서버 message:send가 같은
/// 값으로 다시 검사한다.
const postTitleMaxLength = 100;
const postTextMaxLength = 20000;
const postAttachmentsMaxCount = 30;

/// 게시글 제목·본문의 글자 수 — 서버(permissions.js graphemeLength)처럼 눈에 보이는 글자 단위로
/// 센다(이모지·조합 문자 한 덩어리 = 1자). UTF-16 길이로 세면 입력칸(maxLength)이 받아 준 이모지
/// 제목이 한도 초과로 막힌다.
int postTextLength(String text) => text.characters.length;

/// 모르는 타입(보드 게시글 'post'·투표 'poll' 포함)은 text로 읽는다 — 게시글·투표는 제목/본문이
/// text에 있어서 예전 화면에서도 글로 보이고, 새 enum 값을 만들면 타입별 switch들이 전부
/// 깨지므로 [Message.isPost]·[Message.isPoll]로만 구분한다.
MessageType _typeFromString(String? s) => switch (s) {
  'image' => MessageType.image,
  'file' => MessageType.file,
  'sticker' => MessageType.sticker,
  'system' => MessageType.system,
  _ => MessageType.text,
};

class Message {
  final String id;
  final String roomId;

  /// 작성자가 없는 시스템·자동화 메시지([isAutomation])와 탈퇴한 사람의 메시지는 null
  /// (서버 rooms.js의 postSystemMessage 참고).
  final String? senderId;
  final String senderName;

  /// 사진·파일 메시지의 첨부를 전부 지우고 설명글만 남기면 글 메시지로 바뀐다(applyEdit) — 그래서 non-final.
  MessageType type;

  /// 수정하면 그 자리에서 바뀐다(RoomChatController.applyEdit) — 그래서 non-final.
  String? text;

  /// [text]에 걸린 글자 서식(굵게 등). 수정하면 같이 바뀐다.
  List<TextFormatRun>? textFormat;

  /// [text] 안의 멘션 구간(@이름·@all). 수정하면 같이 바뀐다. 비밀 대화는 늘 빈 목록.
  List<Mention> mentions;

  /// 서버 기준 상대 경로. 표시할 땐 Session.resolveUrl로 절대 주소를 만듭니다. 첨부를 지워 첫 첨부가
  /// 바뀌면 같이 바뀌므로(applyEdit) non-final.
  String? fileUrl;

  /// 비밀 대화에서는 서버가 실제 파일명/종류를 못 보게 더미 값("encrypted" 등)만 받고,
  /// 복호화한 뒤 원본 값으로 그 자리에서 덮어쓴다(Session.decryptInPlace 참고) — 그래서 non-final.
  String? fileName;
  int? fileSize;
  String? mimeType;
  final DateTime createdAt;

  /// 작성 후 5분 이내 본인만 수정 가능(서버가 최종 검증). null이면 수정된 적 없음.
  DateTime? editedAt;

  /// 소프트 삭제됐으면 true — 본문 대신 "삭제된 메시지입니다"를 보여준다. 그 자리에서 바뀌므로 non-final.
  bool deleted;

  /// 이 메시지가 요청한 페이지(창)에 들어서 온 게 아니라, "창 시간대에 달린 댓글의 부모"라서
  /// 서버가 추가로 딸려 보낸 것이면 true(서버 rooms.js의 /rooms/:id/messages 참고).
  /// 옛 메시지에 최근 댓글이 달린 경우가 이에 해당한다. 페이지네이션 커서(다음에 어디부터 더
  /// 불러올지)를 잡을 때는 이런 항목을 빼야 한다 — 창보다 훨씬 오래된 시각이라, 커서로 쓰면
  /// 그 사이 메시지를 통째로 건너뛴다.
  final bool outOfWindow;

  /// 비밀 대화 메시지인데 로컬에 이 epoch/n을 복호화할 체인키가 없어서(재키잉을 2번 이상
  /// 놓쳤거나 다른 기기에서 온 세션 등) 복호화에 실패했으면 true. text는 이때 null이고
  /// UI는 "🔒 이 메시지는 복호화할 수 없습니다" 플레이스홀더를 보여준다(secret_chat_crypto.dart 참고).
  bool decryptFailed;

  /// 비밀 대화의 이미지/파일 첨부 복호화 키/nonce(base64) — 서버가 갖고 있는 fileUrl은 암호화된
  /// 바이트라, 실제로 보여주려면 다운로드 후 이 키로 한 번 더 복호화해야 한다(secret_chat_crypto.dart
  /// decryptAttachment 참고). 비밀 대화가 아니면 항상 null.
  String? attachmentKey;
  String? attachmentNonce;

  /// 이미지 메시지의 축소 미리보기 경로(채팅 버블용) — null이면 썸네일이 없어 원본(fileUrl)을
  /// 그대로 보여준다. 비밀 대화의 thumbnailKey/Nonce는 attachmentKey/Nonce와 동일한 방식으로
  /// 썸네일 전용 키다(원본과 다른 랜덤 키로 따로 암호화됨) — Session.decryptInPlace가 첨부
  /// 봉투에서 풀어서 채운다.
  String? thumbnailUrl;
  String? thumbnailKey;
  String? thumbnailNonce;

  /// 이 메시지에 딸린 첨부들. 서버가 늘 채워 보낸다 — 예전 메시지는 위의 fileUrl 한 칸을
  /// 첨부 하나로 바꿔서 내려주므로, 화면은 이 목록만 보면 된다(사진 여러 장이면 격자). 수정에서 첨부를
  /// 지우면 그 자리에서 바뀐다(applyEdit) — non-final.
  List<MessageAttachment> attachments;

  /// 파일 패널(GET /api/attachments)의 한 줄이 가리키는 첨부 id — 여러 첨부를 한 줄씩 펼친 목록이라 줄마다
  /// 다르다(그 외 경로에서는 null). 파일 삭제가 어느 첨부인지 알려 줄 때 쓴다.
  final String? attachmentId;

  /// 비밀 대화 자동 삭제 타이머용 — 상대가 이 메시지를 읽은 시각(null이면 아직 안 읽음)과,
  /// 그때부터 방의 타이머(초)만큼 지나 삭제될 시각. secret:message-read 브로드캐스트로 그 자리에서
  /// 채워지므로(RoomChatController.applyMessageRead) non-final. 평문 방 메시지는 항상 둘 다 null.
  DateTime? readAt;
  DateTime? expiresAt;

  /// 이 항목이 실제 메시지가 아니라 댓글 타임라인 합성 항목(type == MessageType.comment)일 때만
  /// 채워진다. 그 댓글의 원본 정보는 그대로 여기 있고, "어느 메시지에 달린 댓글인지"는
  /// asComment.messageId로 알 수 있다.
  final Comment? asComment;

  /// 이 메시지에 달린 댓글들(원본 메시지 쪽에만 채워짐). 서버 응답에는 있을 수도 없을 수도
  /// 있지만(방 메시지 목록 조회에는 포함, 실시간 message:new에는 안 옴 — 새 메시지는 어차피
  /// 댓글이 없으므로), 리스트 자체는 항상 이 메시지 전용으로 새로 만들어서 실시간 댓글이 도착할
  /// 때 그 자리에서 추가한다(RoomChatController.addComment 참고) — 그래서 인스턴스마다 독립된
  /// growable list여야 한다.
  final List<Comment> comments;

  /// "메시지 공유"로 이 메시지에 인용된 원본의 스냅샷(message_share_screen.dart) — 원본이 다른
  /// 방일 수 있어 실시간 조회 대신 공유 당시 내용을 그대로 들고 있다. 인용이 아니면 둘 다 null.
  final String? quotedSenderName;
  final String? quotedPreview;

  /// "메시지 전달"로 이 메시지가 생겼고, 전달 화면의 "포함" 토글이 켜져 있었으면 원본 발신자/
  /// 시각(message_forward_screen.dart). 토글이 꺼져 있었거나 전달된 메시지가 아니면 둘 다 null.
  final String? forwardedFromSenderName;
  final DateTime? forwardedFromCreatedAt;

  /// 이 메시지 텍스트에 담긴 링크의 미리보기(있으면). 전송 직후엔 null이다가 서버가 백그라운드로
  /// 가져오면 message:linkPreview로 그 자리에서 채워진다(RoomChatController.applyLinkPreview) —
  /// 그래서 non-final.
  LinkPreview? linkPreview;

  /// "팀장에게 문의하기"(chat_input_bar.dart)로 보낸 메시지면 true — message_bubble.dart가
  /// "문의함 바로가기" 링크를 붙여서 누르면 [inquiryId]로 문의함이 바로 열리게 한다.
  final bool isInquiryNotice;
  final String? inquiryId;

  /// 보드 뷰 게시글(서버 type 'post')인지 — [type]은 text로 두고(본문은 [text]) 이 값으로만
  /// 구분한다(_typeFromString 참고).
  final bool isPost;

  /// 게시글 제목(게시글이 아니면 null). 수정하면 그 자리에서 바뀐다(applyEdit) — non-final.
  String? title;

  /// 게시글을 고정한 시각(null이면 고정 안 됨). 고정/해제가 message:edited로 와서 그 자리에서
  /// 바뀐다 — non-final.
  DateTime? pinnedAt;

  /// 투표 메시지(서버 type 'poll')인지 — 게시글처럼 [type]은 text로 두고(제목이 [text]에 들어 있어
  /// 예전 화면에서도 글로 보인다) 이 값으로만 구분한다. 삭제된 투표도 true지만 [poll]은 null이다.
  final bool isPoll;

  /// 투표 내용(투표가 아니거나 삭제됐으면 null). 투표/마감/즐겨찾기가 오면 그 자리에서 바뀐다
  /// (RoomChatController.applyPollUpdate) — non-final.
  Poll? poll;

  /// "앨범 공유"로 보낸 글에 붙은 앨범 카드(album_share_dialog.dart) — 아니면 null. 메시지 자체는 일반 글이다.
  final SharedAlbum? sharedAlbum;

  Message({
    required this.id,
    required this.roomId,
    this.senderId,
    required this.senderName,
    required this.type,
    this.text,
    this.textFormat,
    List<Mention>? mentions,
    this.fileUrl,
    this.fileName,
    this.fileSize,
    this.mimeType,
    required this.createdAt,
    this.editedAt,
    this.deleted = false,
    this.decryptFailed = false,
    this.attachmentKey,
    this.attachmentNonce,
    this.thumbnailUrl,
    this.attachments = const [],
    this.attachmentId,
    this.thumbnailKey,
    this.thumbnailNonce,
    this.readAt,
    this.expiresAt,
    this.asComment,
    this.outOfWindow = false,
    this.quotedSenderName,
    this.quotedPreview,
    this.forwardedFromSenderName,
    this.forwardedFromCreatedAt,
    this.linkPreview,
    this.isInquiryNotice = false,
    this.inquiryId,
    this.isPost = false,
    this.title,
    this.pinnedAt,
    this.isPoll = false,
    this.poll,
    this.sharedAlbum,
    List<Comment>? comments,
  }) : comments = comments ?? [],
       mentions = mentions ?? <Mention>[];

  /// 지우지 않은 첨부들 — 파일 삭제로 자리만 남은 첨부([MessageAttachment.deleted])를 뺀 목록.
  /// 전달·다운로드·게시글/투표 첨부 목록처럼 "실제 파일"만 다루는 곳에서 쓴다.
  List<MessageAttachment> get liveAttachments => [
    for (final a in attachments)
      if (!a.deleted) a,
  ];

  /// 고정된 게시글인지(보드 상단 "고정된 게시글").
  bool get isPinned => pinnedAt != null;

  /// 프로젝트 자동화(채팅방 알림)가 보낸 메시지 — 사람이 아니라서 senderId가 null인 일반 글 메시지다.
  /// 안읽음·알림은 일반 메시지처럼 가지만, 누구의 "내 메시지"도 아니고 프로필도 없다. 탈퇴한
  /// 사람의 메시지도 senderId가 null이라 보낸 사람 이름까지 같이 본다.
  bool get isAutomation =>
      senderId == null &&
      type == MessageType.text &&
      senderName == automationSenderName;

  /// 채팅 목록에서 [other]와 "같은 사람이 연달아 보낸" 메시지로 묶을지(프로필·시간을 한 번만
  /// 보여줄지). senderId가 null인 메시지는 자동화·탈퇴한 사람 등 여럿일 수 있어서 보낸 사람
  /// 이름까지 같아야 같은 사람으로 본다.
  bool sameSenderAs(Message other) =>
      senderId == other.senderId &&
      (senderId != null || senderName == other.senderName);

  factory Message.fromJson(Map<String, dynamic> json) {
    return Message(
      id: json['id'] as String,
      roomId: json['roomId'] as String,
      senderId: json['senderId'] as String?,
      senderName: json['senderName'] as String,
      type: _typeFromString(json['type'] as String?),
      text: json['text'] as String?,
      textFormat: parseTextFormat(json['textFormat']),
      mentions: parseMentions(json['mentions']),
      fileUrl: json['fileUrl'] as String?,
      fileName: json['fileName'] as String?,
      fileSize: (json['fileSize'] as num?)?.toInt(),
      mimeType: json['mimeType'] as String?,
      thumbnailUrl: json['thumbnailUrl'] as String?,
      attachments:
          (json['attachments'] as List?)
              ?.map(
                (e) => MessageAttachment.fromJson(e as Map<String, dynamic>),
              )
              .toList() ??
          const [],
      attachmentId: json['attachmentId'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num).toInt(),
      ),
      editedAt: (json['editedAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['editedAt'] as num).toInt(),
            )
          : null,
      deleted: json['deleted'] as bool? ?? false,
      outOfWindow: json['outOfWindow'] as bool? ?? false,
      readAt: (json['readAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch((json['readAt'] as num).toInt())
          : null,
      expiresAt: (json['expiresAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['expiresAt'] as num).toInt(),
            )
          : null,
      comments: (json['comments'] as List?)
          ?.map((e) => Comment.fromJson(e as Map<String, dynamic>))
          .toList(),
      quotedSenderName: json['quotedSenderName'] as String?,
      quotedPreview: json['quotedPreview'] as String?,
      forwardedFromSenderName: json['forwardedFromSenderName'] as String?,
      forwardedFromCreatedAt: (json['forwardedFromCreatedAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['forwardedFromCreatedAt'] as num).toInt(),
            )
          : null,
      linkPreview: json['linkPreview'] == null
          ? null
          : LinkPreview.fromJson(json['linkPreview'] as Map<String, dynamic>),
      isInquiryNotice: json['isInquiryNotice'] as bool? ?? false,
      inquiryId: json['inquiryId'] as String?,
      isPost: json['type'] == 'post',
      title: json['title'] as String?,
      pinnedAt: (json['pinnedAt'] as num?) != null
          ? DateTime.fromMillisecondsSinceEpoch(
              (json['pinnedAt'] as num).toInt(),
            )
          : null,
      isPoll: json['type'] == 'poll',
      poll: json['poll'] == null
          ? null
          : Poll.fromJson(Map<String, dynamic>.from(json['poll'] as Map)),
      sharedAlbum: SharedAlbum.fromJson(json['sharedAlbum']),
    );
  }

  /// 댓글 하나를 채팅 타임라인에 그 댓글이 달린 시각 위치에 끼워 넣기 위한 합성 항목.
  factory Message.commentEntry(Comment c) {
    return Message(
      id: 'comment:${c.id}',
      roomId: c.roomId,
      senderId: c.senderId,
      senderName: c.senderName,
      type: MessageType.comment,
      createdAt: c.createdAt,
      asComment: c,
    );
  }
}

/// 메시지 하나에 딸린 첨부 한 개. 사진을 여러 장 보내면 한 메시지에 여러 개가 들어오고,
/// 채팅 버블은 그걸 격자로 보여준다.
class MessageAttachment {
  final String id;

  /// 'image' | 'file'
  final String kind;
  final String fileUrl;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final String? thumbnailUrl;

  /// 파일 삭제(업로드한 본인·팀 관리자)로 지워진 첨부 — 서버가 경로([fileUrl])를 비우고 이름만 남겨 내려준다.
  /// 말풍선은 이 자리를 "삭제된 파일입니다" 카드로 그린다(메시지와 댓글은 그대로 남는다).
  final bool deleted;

  const MessageAttachment({
    required this.id,
    required this.kind,
    required this.fileUrl,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.thumbnailUrl,
    this.deleted = false,
  });

  bool get isImage => kind == 'image';

  factory MessageAttachment.fromJson(Map<String, dynamic> json) =>
      MessageAttachment(
        id: json['id'] as String,
        kind: json['kind'] as String? ?? 'file',
        fileUrl: json['fileUrl'] as String? ?? '',
        fileName: json['fileName'] as String?,
        fileSize: (json['fileSize'] as num?)?.toInt(),
        mimeType: json['mimeType'] as String?,
        thumbnailUrl: json['thumbnailUrl'] as String?,
        deleted: json['deleted'] as bool? ?? false,
      );
}
