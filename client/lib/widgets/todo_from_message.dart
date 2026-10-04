import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/todo.dart';
import '../screens/todo_editor_dialog.dart';
import '../services/room_chat_controller.dart' show UploadedAttachment;
import '../services/session.dart';
import '../services/todo_api.dart';
import 'app_toast.dart';

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
