import 'package:flutter/material.dart';

import '../models/message.dart';
import '../models/room.dart';
import '../services/api_client.dart' show ApiException;
import '../services/session.dart';
import 'app_toast.dart';

/// 메시지 더보기(PC ⋯ 메뉴)·길게 누르기 시트(모바일)의 "공지 등록" — 잔디처럼 **일반 텍스트 메시지와 이미지
/// 메시지만** 공지로 올릴 수 있다(파일·이모티콘·시스템·보드 게시글·투표·댓글·삭제된 메시지는 안 된다).
/// 공지는 토픽 기능이라 그룹·1:1·비밀 대화에서는 항목 자체가 없다. 권한은 공지를 새로 쓰는 것과 같다
/// ([Session.canCreateAnnouncementIn] — 토픽을 만들 수 있는 사람과 그 토픽의 관리자). 이미 이 메시지가 지금
/// 고정된 공지면 다시 올릴 수 없으므로 항목을 숨긴다.
bool canAnnounceMessage(Session session, Message message) {
  if (message.deleted ||
      message.decryptFailed ||
      message.isPost ||
      message.isPoll) {
    return false;
  }
  if (message.type != MessageType.text && message.type != MessageType.image) {
    return false;
  }
  final room = session.roomById(message.roomId);
  if (room == null || room.type != RoomType.topic || room.isSecret) {
    return false;
  }
  if (message.type == MessageType.text) {
    if (message.text?.trim().isEmpty ?? true) return false;
  } else if ((message.fileUrl ?? '').isEmpty && message.attachments.isEmpty) {
    return false;
  }
  if (room.latestAnnouncement?.messageId == message.id) return false;
  return session.canCreateAnnouncementIn(room);
}

/// 메시지를 공지로 등록한다 — 확인 없이 바로 올리고 토스트로 알린다. 이미 고정 공지가 있으면 그 자리를 이
/// 메시지가 차지하고(이전 공지는 공지 목록 히스토리에 남는다) 그 전에 "기존 공지를 이 메시지로 바꿀까요?"만
/// 한 번 묻는다. 배너는 서버의 announcement:new 이벤트로 바뀐다(Session이 받는다).
Future<void> announceMessage(
  BuildContext context,
  Session session,
  Message message,
) async {
  final room = session.roomById(message.roomId);
  if (room == null) return;
  if (room.latestAnnouncement != null) {
    final replace = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('공지 등록'),
        content: const Text('기존 공지를 이 메시지로 바꿀까요?\n기존 공지는 공지 목록에 기록으로 남습니다.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('취소'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('바꾸기'),
          ),
        ],
      ),
    );
    if (replace != true || !context.mounted) return;
  }
  // 토스트는 Overlay를 잡아 두고 쓴다 — 더보기 메뉴가 닫히면 이 context가 죽을 수 있다.
  final overlay = Overlay.maybeOf(context, rootOverlay: true);
  try {
    await session.api!.createAnnouncementFromMessage(room.id, message.id);
    if (overlay != null) showAppToastOnOverlay(overlay, '공지로 등록했습니다.');
  } on ApiException catch (e) {
    if (overlay != null) {
      showAppToastOnOverlay(overlay, '공지 등록 실패: ${e.message}');
    }
  } catch (e) {
    if (overlay != null) showAppToastOnOverlay(overlay, '공지 등록 실패: $e');
  }
}

/// 말풍선의 작은 "공지" 표시 — 이 메시지가 지금 이 토픽의 고정 공지로 올라가 있을 때만 붙는다.
bool isPinnedAnnouncementSource(Session session, Message message) =>
    session.roomById(message.roomId)?.latestAnnouncement?.messageId ==
    message.id;
