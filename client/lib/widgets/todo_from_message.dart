import 'package:flutter/material.dart';

import '../models/app_notification.dart';
import '../models/message.dart';
import '../models/todo.dart';
import '../screens/todo_editor_dialog.dart';
import '../services/room_chat_controller.dart' show UploadedAttachment;
import '../services/session.dart';
import '../services/todo_api.dart';
import 'app_toast.dart';
import 'message_actions.dart' show messageFromComment;

/// 메시지·댓글 더보기의 "할 일로 등록"을 보여줄 수 있는지 — 일반 텍스트·사진·파일만(시스템·투표·게시글·스티커·삭제된
/// 글은 뺀다), 비밀 대화와 할 일을 만들 수 없는 방(읽기 전용·보관 토픽의 일반 멤버)도 뺀다.
bool canRegisterAsTodo(Session session, Message message) {
  if (message.deleted || message.isPoll || message.isPost) return false;
  if (message.type != MessageType.text &&
      message.type != MessageType.image &&
      message.type != MessageType.file) {
    return false;
  }
  final room = session.rooms.where((r) => r.id == message.roomId).firstOrNull;
  if (room == null) return false;
  return session.canCreateTodoIn(room);
}

/// 메시지(또는 댓글)에 붙은 첨부 — 첨부 목록이 있으면 그것, 없으면 예전 방식의 파일 칸 하나(댓글이 이 모양).
/// 지워진 첨부는 뺀다. 최대 [todoAttachmentsMaxCount]개.
List<UploadedAttachment> todoAttachmentsOf(Message message) {
  final list = <UploadedAttachment>[
    for (final a in message.attachments)
      if (!a.deleted && a.fileUrl.isNotEmpty)
        UploadedAttachment.fromMessageAttachment(a),
  ];
  if (list.isEmpty &&
      (message.type == MessageType.image || message.type == MessageType.file) &&
      (message.fileUrl ?? '').isNotEmpty) {
    list.add(
      UploadedAttachment(
        isImage: message.type == MessageType.image,
        url: message.fileUrl!,
        fileName: message.fileName ?? '',
        size: message.fileSize ?? 0,
        mimeType: message.mimeType,
        thumbnailUrl: message.thumbnailUrl,
      ),
    );
  }
  return list.take(todoAttachmentsMaxCount).toList();
}

/// 메시지·댓글을 할 일로 등록한다 — 대화방이 그 방으로 고정된 생성 창이 열리고, 제목에 본문 첫 줄(최대 100자)·설명에
/// 본문·첨부가 미리 채워진다(모두 고칠 수 있다). 만들어지면 알린다. [isComment]면 [message]는 댓글을 감싼 합성 메시지
/// (message_actions.dart의 messageFromComment)이고, 서버에는 sourceCommentId로 보낸다.
Future<void> registerMessageAsTodo(
  BuildContext context, {
  required Session session,
  required Message message,
  bool isComment = false,
  TodoApi? api,
}) async {
  final room = session.rooms.where((r) => r.id == message.roomId).firstOrNull;
  if (room == null) return;
  final body = (message.text ?? '').trim();
  final attachments = todoAttachmentsOf(message);
  final saved = await showTodoEditor(
    context,
    session: session,
    room: room,
    lockRoom: true,
    // 글 없이 사진·파일만 있는 메시지는 첫 파일 이름을 제목 후보로 쓴다.
    initialTitle: todoTitleFromText(
      body.isNotEmpty ? body : attachments.firstOrNull?.fileName,
    ),
    initialDescription: body,
    initialAttachments: attachments,
    sourceMessageId: isComment ? null : message.id,
    sourceCommentId: isComment ? message.id : null,
    api: api,
  );
  if (saved != null && context.mounted) {
    showAppToast(context, '할 일로 등록했습니다.');
  }
}

/// 알림 센터 멘션 알림의 ⋯에 "할 일로 등록"을 보여줄 수 있는지 — 멘션(@all 포함) 알림이고, 그 방이 내 목록에 있으며 할 일을
/// 만들 수 있는 방일 때만(비밀 대화·보드 뷰 토픽·읽기 전용/보관 토픽의 일반 멤버는 [SessionTodos.canCreateTodoIn]이 뺀다).
bool canRegisterNotificationAsTodo(
  Session session,
  AppNotification notification,
) {
  if (!notification.isMention) return false;
  final roomId = notification.roomId;
  final room = roomId == null ? null : session.roomById(roomId);
  return room != null && session.canCreateTodoIn(room);
}

/// 알림 미리보기의 최대 길이 — 서버(notificationRules.js의 PREVIEW_MAX)가 공백·줄바꿈을 한 칸으로 줄인 글을 이 길이
/// (코드 포인트)에서 말줄임표 없이 자른다.
const notificationPreviewMaxLength = 120;

/// 알림 센터의 멘션 알림을 할 일로 등록한다(잔디: [알림센터] > [멘션] > 메시지 […] > [할 일] — 그 메시지의 […]라서 채팅에서
/// 등록할 때와 같은 할 일이 된다). 알림의 미리보기(한 줄로 줄이고 잘린, 알림 때의 글) 대신 지금의 원본 — 댓글 멘션이면 그
/// 댓글, 아니면 그 메시지 — 을 서버에서 받아 [registerMessageAsTodo]로 연다: 대화방 고정, 제목은 본문 첫 줄, 설명은
/// 줄바꿈을 살린 본문 전체, 첨부도 그대로. 원본을 못 받으면(지워졌거나 방을 나갔거나 연결 실패) 미리보기로 채운 같은 창을
/// 연다(첨부 없음, 미리보기가 잘렸으면 설명 끝에 '…'). 그새 그 방을 나갔으면 알리고 만다. 만들어지면 알린다.
Future<void> registerNotificationAsTodo(
  BuildContext context, {
  required Session session,
  required AppNotification notification,
  TodoApi? api,
}) async {
  final roomId = notification.roomId;
  final room = roomId == null ? null : session.roomById(roomId);
  if (room == null) {
    showAppToast(context, '더 이상 볼 수 없는 대화입니다.');
    return;
  }
  final commentId = notification.commentId;
  final original = await _fetchNotificationOriginal(session, notification);
  if (!context.mounted) return;
  if (original != null) {
    await registerMessageAsTodo(
      context,
      session: session,
      message: original,
      isComment: commentId != null,
      api: api,
    );
    return;
  }
  final preview = notification.preview.trim();
  final saved = await showTodoEditor(
    context,
    session: session,
    room: room,
    lockRoom: true,
    initialTitle: todoTitleFromText(preview),
    // 서버가 잘랐을 수 있는 길이면 잘렸다는 것이 보이게 — 제목은 어차피 100자에서 잘리고, 붙이면 길이 제한을 넘는다.
    initialDescription: preview.runes.length >= notificationPreviewMaxLength
        ? '$preview…'
        : preview,
    sourceMessageId: commentId == null ? notification.messageId : null,
    sourceCommentId: commentId,
    api: api,
  );
  if (saved != null && context.mounted) {
    showAppToast(context, '할 일로 등록했습니다.');
  }
}

/// 알림이 가리키는 지금의 원본 — 댓글 멘션이면 그 댓글을 감싼 합성 메시지([messageFromComment]), 아니면 그 메시지.
/// 서버가 거절하거나(지워짐·방 멤버 아님 — 404/403) 연결이 안 되거나, 받은 글이 지워졌거나 다른 방의 글이면 null.
Future<Message?> _fetchNotificationOriginal(
  Session session,
  AppNotification notification,
) async {
  final api = session.api;
  final commentId = notification.commentId;
  final messageId = notification.messageId;
  if (api == null) return null;
  try {
    final Message original;
    if (commentId != null) {
      final comment = await api.fetchComment(commentId);
      if (comment.deleted) return null;
      original = messageFromComment(comment);
    } else if (messageId != null) {
      original = await api.fetchMessage(messageId);
      if (original.deleted) return null;
    } else {
      return null;
    }
    return original.roomId == notification.roomId ? original : null;
  } catch (_) {
    // 옛 서버(단건 조회가 없음)·연결 끊김 등 — 미리보기로 채운다.
    return null;
  }
}
