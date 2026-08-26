import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/comment.dart';
import '../models/message.dart';
import '../models/room.dart';
import 'session.dart';

/// 방 하나의 메시지 목록/전송을 담당하는 컨트롤러. 방을 열 때 Session이 생성해서 캐싱한다.
class RoomChatController extends ChangeNotifier {
  RoomChatController(this._session, this.room)
    : readBoundary = room.lastRead[_session.userId] ?? 0 {
    _readSub = _session.chatSocket.readEvents
        .where((e) => e.roomId == room.id)
        .listen((_) => notifyListeners());
    _load();
  }

  final Session _session;
  final Room room;
  final List<Message> messages = [];
  bool loading = true;
  String? error;
  StreamSubscription? _readSub;

  /// 이 방을 이번 세션에서 처음 열었을 때(=아직 markReadNow가 실행되기 전) 내가 읽었던 지점.
  /// "여기까지 읽었습니다" 구분선을 이 값 기준으로 그린다 — 컨트롤러가 세션 내내 캐싱되므로
  /// 한 번 정해지면 이 방을 다시 열어도 안 바뀐다(방을 나갔다가 새로 들어와야 갱신됨).
  final int readBoundary;

  Future<void> _load() async {
    try {
      final history = await _session.api!.fetchRoomMessages(room.id);
      _mergeHistory(history);
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    notifyListeners();
    markReadNow();
  }

  /// REST로 받아온 메시지 목록(history)을 messages에 합친다. 새 메시지는 그대로 추가하고, 이미
  /// 있는 메시지는 그 사이 새로 달렸을 수 있는 댓글만 id로 비교해서 보충한다(재연결 동안 놓쳤을
  /// 수 있는 comment:new를 이렇게 뒤늦게라도 따라잡는다). 댓글은 원본 메시지의 comments에 쌓는
  /// 동시에, 그 댓글이 달린 시각 위치에 보이도록 타임라인에도 합성 항목(Message.commentEntry)으로
  /// 끼워 넣는다. 뭔가 하나라도 바뀌면 true를 돌려준다.
  bool _mergeHistory(List<Message> history) {
    final byId = {for (final m in messages) m.id: m};
    final newMessages = <Message>[];
    final newCommentEntries = <Message>[];

    for (final incoming in history) {
      final existing = byId[incoming.id];
      if (existing == null) {
        newMessages.add(incoming);
        newCommentEntries.addAll(incoming.comments.map(Message.commentEntry));
        continue;
      }
      final existingCommentIds = existing.comments.map((c) => c.id).toSet();
      for (final c in incoming.comments) {
        if (existingCommentIds.add(c.id)) {
          existing.comments.add(c);
          newCommentEntries.add(Message.commentEntry(c));
        }
      }
    }

    if (newMessages.isEmpty && newCommentEntries.isEmpty) return false;
    messages
      ..addAll(newMessages)
      ..addAll(newCommentEntries)
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    return true;
  }

  /// Session이 이 방으로 들어온 실시간 메시지를 라우팅할 때 호출한다.
  void feed(Message m) {
    messages.add(m);
    notifyListeners();
    // 지금 이 방을 실제로 보고 있을 때만 읽음 처리한다 (백그라운드/다른 방을 보는 중이면 안읽음으로 남겨야 함).
    if (_session.activeRoomId == room.id && _session.appInForeground)
      markReadNow();
  }

  /// Session이 이 방으로 들어온 실시간 댓글(comment:new)을 라우팅할 때 호출한다. 원본 메시지가
  /// 아직 로드된 범위 밖이면 조용히 무시한다(그 메시지를 스크롤해서 보게 되면 REST로 다시
  /// 불러올 때 댓글이 이미 함께 포함돼서 온다 — rooms.js의 /rooms/:id/messages 참고).
  void addComment(Comment c) {
    final idx = messages.indexWhere((m) => m.id == c.messageId);
    if (idx == -1) return;
    final message = messages[idx];
    if (message.comments.any((x) => x.id == c.id))
      return; // 재연결 재전송 등으로 인한 중복 방지.
    message.comments.add(c);
    messages
      ..add(Message.commentEntry(c))
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    notifyListeners();
  }

  /// 댓글을 단다. 실제 목록 갱신은 이 요청이 성공하면 서버가 보내는 comment:new 브로드캐스트로
  /// 이뤄진다(보낸 사람도 그 방 소켓에 있으므로 자기 자신도 받는다 — sendText와 동일한 방식이라
  /// 여기서 낙관적으로 먼저 추가할 필요가 없다).
  Future<void> postComment(String messageId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Future.value();
    return _session.api!.addComment(messageId, text: trimmed);
  }

  /// 댓글에 이미지/파일을 첨부해서 단다. [caption]을 같이 주면(첨부 후 텍스트도 입력한 경우)
  /// 그 댓글 하나에 첨부와 텍스트가 함께 실린다 — sendFile과 동일한 방식.
  Future<void> postCommentFile(
    String messageId,
    File file, {
    required bool isImage,
    String? caption,
  }) async {
    final result = await _session.api!.uploadFile(file);
    final trimmedCaption = caption?.trim();
    await _session.api!.addComment(
      messageId,
      text: trimmedCaption?.isNotEmpty == true ? trimmedCaption : null,
      type: isImage ? 'image' : 'file',
      fileUrl: result.url,
      fileName: result.fileName,
      fileSize: result.size,
      mimeType: result.mimeType,
    );
  }

  /// 댓글을 수정한다(본인, 작성 5분 이내만 서버가 허용). 실제 반영은
  /// comment:edited 브로드캐스트(applyCommentEdit)로 이뤄진다.
  Future<void> editComment(String commentId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Future.value();
    return _session.api!.editComment(commentId, trimmed);
  }

  /// 댓글을 삭제한다(본인, 작성 5분 이내만 서버가 허용). 실제 반영은
  /// comment:deleted 브로드캐스트(applyCommentDelete)로 이뤄진다.
  Future<void> deleteComment(String commentId) =>
      _session.api!.deleteComment(commentId);

  /// Session이 comment:edited 브로드캐스트를 라우팅할 때 호출한다. 합성 타임라인 항목의
  /// asComment와 원본 메시지의 comments 리스트 항목은 같은 Comment 인스턴스를 공유하므로
  /// (addComment/_mergeHistory 참고), 이 인스턴스 하나만 찾아 그 자리에서 바꾸면 양쪽에 함께 반영된다.
  void applyCommentEdit(Comment edited) {
    final entry = _findCommentEntry(edited.id);
    if (entry == null) return;
    entry.asComment!.text = edited.text;
    entry.asComment!.editedAt = edited.editedAt;
    notifyListeners();
  }

  /// Session이 comment:deleted 브로드캐스트를 라우팅할 때 호출한다.
  void applyCommentDelete(String commentId) {
    final entry = _findCommentEntry(commentId);
    if (entry == null) return;
    entry.asComment!.deleted = true;
    notifyListeners();
  }

  Message? _findCommentEntry(String commentId) {
    for (final m in messages) {
      if (m.type == MessageType.comment && m.asComment!.id == commentId)
        return m;
    }
    return null;
  }

  /// 메시지를 수정한다(텍스트 메시지, 본인, 작성 5분 이내만 서버가 허용). 실제 반영은
  /// message:edited 브로드캐스트(applyEdit)로 이뤄진다.
  Future<void> editMessage(String messageId, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Future.value();
    return _session.api!.editMessage(messageId, trimmed);
  }

  /// 메시지를 삭제한다(본인, 작성 5분 이내만 서버가 허용). 실제 반영은
  /// message:deleted 브로드캐스트(applyDelete)로 이뤄진다.
  Future<void> deleteMessage(String messageId) =>
      _session.api!.deleteMessage(messageId);

  /// Session이 message:edited 브로드캐스트를 라우팅할 때 호출한다.
  void applyEdit(Message edited) {
    final idx = messages.indexWhere((m) => m.id == edited.id);
    if (idx == -1) return;
    messages[idx].text = edited.text;
    messages[idx].editedAt = edited.editedAt;
    notifyListeners();
  }

  /// Session이 message:deleted 브로드캐스트를 라우팅할 때 호출한다. 리스트에서 빼지 않고
  /// deleted만 세운다 — 댓글 스레드가 이 메시지를 계속 참조하고, "삭제된 메시지입니다"로
  /// 표시만 바뀌어야 하기 때문이다.
  void applyDelete(String messageId) {
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;
    messages[idx].deleted = true;
    notifyListeners();
  }

  /// 연결이 끊겼다가 다시 붙었을 때 Session이 호출한다. 끊긴 동안 놓쳤을 수 있는 메시지/댓글을
  /// 다시 받아와 합친다.
  Future<void> refresh() async {
    try {
      final history = await _session.api!.fetchRoomMessages(room.id);
      if (!_mergeHistory(history)) return;
      notifyListeners();
      if (_session.activeRoomId == room.id && _session.appInForeground)
        markReadNow();
    } catch (_) {
      // 재연결 직후 갱신 실패는 조용히 넘어간다 — 다음 재연결 때 다시 시도됨.
    }
  }

  /// 검색 결과 등에서 특정 메시지로 바로 스크롤하고 싶을 때 쓴다. 그 메시지가 아직 로드된
  /// 범위 밖(기본 50개보다 오래됨)이면 훨씬 넉넉하게 다시 가져와서 채운다.
  Future<void> ensureMessageLoaded(String messageId) async {
    if (messages.any((m) => m.id == messageId)) return;
    try {
      final history = await _session.api!.fetchRoomMessages(
        room.id,
        limit: 500,
      );
      if (_mergeHistory(history)) notifyListeners();
    } catch (_) {
      // 실패해도 조용히 무시 — 스크롤/하이라이트만 안 될 뿐 방 자체는 정상적으로 보인다.
    }
  }

  void markReadNow() => _session.chatSocket.markRead(room.id);

  Future<void> sendText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Future.value();
    return _session.chatSocket.send(
      roomId: room.id,
      type: 'text',
      text: trimmed,
    );
  }

  /// [caption]을 같이 주면(이미지/파일 첨부 후 메시지를 입력하고 보낸 경우) 그 메시지 하나에
  /// 텍스트와 첨부가 함께 실린다.
  Future<void> sendFile(
    File file, {
    required bool isImage,
    String? caption,
  }) async {
    final result = await _session.api!.uploadFile(file);
    final trimmedCaption = caption?.trim();
    await _session.chatSocket.send(
      roomId: room.id,
      type: isImage ? 'image' : 'file',
      text: trimmedCaption?.isNotEmpty == true ? trimmedCaption : null,
      fileUrl: result.url,
      fileName: result.fileName,
      fileSize: result.size,
      mimeType: result.mimeType,
    );
  }

  @override
  void dispose() {
    _readSub?.cancel();
    super.dispose();
  }
}
