import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/comment.dart';
import '../models/message.dart';
import '../models/room.dart';
import 'api_client.dart' show UploadCancelToken;
import 'secret_chat_crypto.dart' as secret_crypto;
import 'session.dart';

/// 첨부 업로드가 끝난 뒤(암호화 여부와 무관하게) 실제 메시지/댓글 전송에 필요한 결과.
/// ChatInputBar/CommentInputBar가 첨부한 즉시 RoomChatController.uploadAttachment로 이 값을
/// 만들어두고, 사용자가 "보내기"를 누르면 sendUploadedAttachment/postUploadedCommentAttachment에
/// 그대로 넘긴다 — 그때는 이미 올라가 있는 파일이라 다시 업로드하지 않는다.
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
}

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

  static const _pageSize = 50;

  /// 위로 스크롤해서 과거 메시지를 더 불러오는 중이면 true — chat_panel.dart가 맨 위 근처에
  /// 작은 로딩 표시를 띄우는 데 쓴다.
  bool loadingMore = false;

  /// 서버에 더 오래된 메시지가 남아있는지. loadOlderMessages()가 요청한 개수보다 적게
  /// 돌려받으면(=그게 방의 시작이다) false로 내려서 더 이상 요청하지 않는다.
  bool hasMoreHistory = true;

  /// 다음 페이지를 요청할 기준 시각(이 시각보다 이전 것을 더 불러온다). messages.first를
  /// 그대로 쓰면 안 된다 — 서버가 "창 시간대 댓글의 부모"를 창 밖에서 추가로 딸려 보내는데
  /// (Message.outOfWindow), 그건 창보다 훨씬 오래된 시각이라 커서로 쓰면 그 사이 메시지를
  /// 통째로 건너뛴다. 그래서 창(페이지)에 실제로 포함된 것들 중 가장 오래된 시각만 쓴다.
  DateTime? _historyCursor;

  /// 이번 응답에서 창에 실제로 포함된(= outOfWindow가 아닌) 항목들로 커서를 갱신한다.
  void _advanceHistoryCursor(List<Message> page) {
    for (final m in page) {
      if (m.outOfWindow) continue;
      final cursor = _historyCursor;
      if (cursor == null || m.createdAt.isBefore(cursor)) {
        _historyCursor = m.createdAt;
      }
    }
  }

  /// 이 방을 이번 세션에서 처음 열었을 때(=아직 markReadNow가 실행되기 전) 내가 읽었던 지점.
  /// "여기까지 읽었습니다" 구분선을 이 값 기준으로 그린다 — 컨트롤러가 세션 내내 캐싱되므로
  /// 한 번 정해지면 이 방을 다시 열어도 안 바뀐다(방을 나갔다가 새로 들어와야 갱신됨).
  final int readBoundary;

  Future<void> _load() async {
    try {
      final history = await _session.api!.fetchRoomMessages(
        room.id,
        limit: _pageSize,
      );
      await _session.decryptHistory(room, history);
      _mergeHistory(history);
      _advanceHistoryCursor(history);
      // 창 밖 부모(outOfWindow)는 페이지 크기 판정에서도 빼야 "끝에 도달했다"를 놓치지 않는다.
      if (history.where((m) => !m.outOfWindow).length < _pageSize) {
        hasMoreHistory = false;
      }
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    notifyListeners();
    markReadNow();
  }

  /// 채팅방 맨 위 근처까지 스크롤했을 때(chat_panel.dart) 그보다 오래된 메시지를 더
  /// 불러와서 앞쪽에 이어붙인다. 이미 불러오는 중이거나 더 가져올 게 없으면 아무것도 안 한다.
  Future<void> loadOlderMessages() async {
    final cursor = _historyCursor;
    if (loadingMore || !hasMoreHistory || cursor == null) return;
    loadingMore = true;
    notifyListeners();
    try {
      final older = await _session.api!.fetchRoomMessages(
        room.id,
        limit: _pageSize,
        before: cursor,
      );
      if (older.where((m) => !m.outOfWindow).length < _pageSize) {
        hasMoreHistory = false;
      }
      if (older.isNotEmpty) {
        await _session.decryptHistory(room, older);
        _mergeHistory(older);
        _advanceHistoryCursor(older);
      }
    } catch (_) {
      // 실패해도 조용히 무시 — 계속 스크롤하면 다시 시도된다.
    } finally {
      loadingMore = false;
      notifyListeners();
    }
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
    var changed = false;

    for (final incoming in history) {
      final existing = byId[incoming.id];
      if (existing == null) {
        newMessages.add(incoming);
        newCommentEntries.addAll(incoming.comments.map(Message.commentEntry));
        continue;
      }
      // 연결이 끊긴 동안 상대가 이 메시지를 읽었을 수도 있다 — secret:message-read 소켓
      // 이벤트를 놓쳤어도, 재연결 시 다시 받아온 히스토리로 자동 삭제 타이머 값을 따라잡는다.
      if (existing.readAt != incoming.readAt ||
          existing.expiresAt != incoming.expiresAt) {
        existing.readAt = incoming.readAt;
        existing.expiresAt = incoming.expiresAt;
        changed = true;
      }
      final existingCommentIds = existing.comments.map((c) => c.id).toSet();
      for (final c in incoming.comments) {
        if (existingCommentIds.add(c.id)) {
          existing.comments.add(c);
          newCommentEntries.add(Message.commentEntry(c));
        }
      }
    }

    if (!changed && newMessages.isEmpty && newCommentEntries.isEmpty) {
      return false;
    }
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
    if (_session.activeRoomId == room.id && _session.appInForeground) {
      markReadNow();
    }
  }

  /// Session이 이 방으로 들어온 실시간 댓글(comment:new)을 라우팅할 때 호출한다. 원본 메시지가
  /// 아직 로드된 범위 밖이면 조용히 무시한다(그 메시지를 스크롤해서 보게 되면 REST로 다시
  /// 불러올 때 댓글이 이미 함께 포함돼서 온다 — rooms.js의 /rooms/:id/messages 참고).
  void addComment(Comment c) {
    final idx = messages.indexWhere((m) => m.id == c.messageId);
    if (idx == -1) return;
    final message = messages[idx];
    if (message.comments.any((x) => x.id == c.id)) {
      return; // 재연결 재전송 등으로 인한 중복 방지.
    }
    message.comments.add(c);
    messages
      ..add(Message.commentEntry(c))
      ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
    notifyListeners();
  }

  /// 댓글을 단다. 실제 목록 갱신은 이 요청이 성공하면 서버가 보내는 comment:new 브로드캐스트로
  /// 이뤄진다(보낸 사람도 그 방 소켓에 있으므로 자기 자신도 받는다 — sendText와 동일한 방식이라
  /// 여기서 낙관적으로 먼저 추가할 필요가 없다).
  Future<void> postComment(String messageId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final payload = await _session.encryptOutgoing(room, trimmed);
    await _session.api!.addComment(messageId, text: payload);
  }

  /// 댓글로 이모티콘을 단다 — sendSticker와 동일한 방식(파일 업로드 없이 id만 전송).
  Future<void> postCommentSticker(String messageId, String stickerId) async {
    final payload = await _session.encryptOutgoing(room, stickerId);
    await _session.api!.addComment(messageId, text: payload, type: 'sticker');
  }

  /// 이미 업로드가 끝난 첨부(uploadAttachment 결과)로 댓글을 단다. [caption]을 같이 주면(첨부
  /// 후 텍스트도 입력한 경우) 그 댓글 하나에 첨부와 텍스트가 함께 실린다.
  Future<void> postUploadedCommentAttachment(
    String messageId,
    UploadedAttachment u, {
    String? caption,
  }) async {
    final trimmedCaption = caption?.trim();
    if (room.isSecret) {
      final envelope = await _session.encryptAttachmentPayload(
        room,
        caption: trimmedCaption?.isNotEmpty == true ? trimmedCaption : null,
        fileName: u.fileName,
        fileSize: u.size,
        mimeType: u.mimeType,
        attachmentKey: u.attachmentKey!,
        attachmentNonce: u.attachmentNonce!,
        thumbnailKey: u.thumbnailKey,
        thumbnailNonce: u.thumbnailNonce,
      );
      await _session.api!.addComment(
        messageId,
        text: envelope,
        type: u.isImage ? 'image' : 'file',
        fileUrl: u.url,
        fileName: 'encrypted',
        fileSize: u.size,
        mimeType: 'application/octet-stream',
        thumbnailUrl: u.thumbnailUrl,
      );
      return;
    }

    await _session.api!.addComment(
      messageId,
      text: trimmedCaption?.isNotEmpty == true ? trimmedCaption : null,
      type: u.isImage ? 'image' : 'file',
      fileUrl: u.url,
      fileName: u.fileName,
      fileSize: u.size,
      mimeType: u.mimeType,
      thumbnailUrl: u.thumbnailUrl,
    );
  }

  /// 댓글을 수정한다(본인, 작성 5분 이내만 서버가 허용). 실제 반영은
  /// comment:edited 브로드캐스트(applyCommentEdit)로 이뤄진다.
  Future<void> editComment(String commentId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final payload = await _session.encryptOutgoing(room, trimmed);
    await _session.api!.editComment(commentId, payload!);
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
    if (room.isSecret) {
      unawaited(_session.secretSessionManager?.forgetDecryptedText(commentId));
    }
    notifyListeners();
  }

  Message? _findCommentEntry(String commentId) {
    for (final m in messages) {
      if (m.type == MessageType.comment && m.asComment!.id == commentId) {
        return m;
      }
    }
    return null;
  }

  /// 메시지를 수정한다(텍스트 메시지, 본인, 작성 5분 이내만 서버가 허용). 실제 반영은
  /// message:edited 브로드캐스트(applyEdit)로 이뤄진다.
  Future<void> editMessage(String messageId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final payload = await _session.encryptOutgoing(room, trimmed);
    await _session.api!.editMessage(messageId, payload!);
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

  /// Session이 message:linkPreview 브로드캐스트를 라우팅할 때 호출한다.
  void applyLinkPreview(Message updated) {
    final idx = messages.indexWhere((m) => m.id == updated.id);
    if (idx == -1) return;
    messages[idx].linkPreview = updated.linkPreview;
    notifyListeners();
  }

  /// Session이 secret:message-read 브로드캐스트를 라우팅할 때 호출한다 — 상대가 이 메시지를
  /// 읽었다는 신호로, 자동 삭제 타이머가 설정된 방이면 여기서부터 카운트다운이 시작된다
  /// (message_bubble.dart의 SelfDestructCountdown이 이 값을 보고 실시간으로 줄어든다).
  void applyMessageRead(
    String messageId,
    DateTime readAt,
    DateTime? expiresAt,
  ) {
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;
    messages[idx].readAt = readAt;
    messages[idx].expiresAt = expiresAt;
    notifyListeners();
  }

  /// Session이 message:deleted 브로드캐스트를 라우팅할 때 호출한다. 리스트에서 빼지 않고
  /// deleted만 세운다 — 댓글 스레드가 이 메시지를 계속 참조하고, "삭제된 메시지입니다"로
  /// 표시만 바뀌어야 하기 때문이다.
  void applyDelete(String messageId) {
    final idx = messages.indexWhere((m) => m.id == messageId);
    if (idx == -1) return;
    messages[idx].deleted = true;
    if (room.isSecret) {
      unawaited(_session.secretSessionManager?.forgetDecryptedText(messageId));
    }
    notifyListeners();
  }

  /// Session이 message:expired(비밀 대화 자동 삭제 타이머 만료)를 라우팅할 때 호출한다.
  /// 소프트 삭제(applyDelete)와 달리 흔적 없이 없어지는 게 취지라 리스트에서 완전히 뺀다 —
  /// 서버가 FK cascade로 댓글도 같이 지웠으므로 그 댓글의 합성 타임라인 항목도 함께 제거한다.
  void applyExpire(String messageId) {
    final removed = <String>[];
    for (final m in messages) {
      if (m.id == messageId ||
          (m.type == MessageType.comment &&
              m.asComment?.messageId == messageId)) {
        removed.add(m.type == MessageType.comment ? m.asComment!.id : m.id);
      }
    }
    messages.removeWhere(
      (m) =>
          m.id == messageId ||
          (m.type == MessageType.comment &&
              m.asComment?.messageId == messageId),
    );
    if (room.isSecret) {
      for (final id in removed) {
        unawaited(_session.secretSessionManager?.forgetDecryptedText(id));
      }
    }
    if (removed.isNotEmpty) notifyListeners();
  }

  /// 연결이 끊겼다가 다시 붙었을 때 Session이 호출한다. 끊긴 동안 놓쳤을 수 있는 메시지/댓글을
  /// 다시 받아와 합친다.
  Future<void> refresh() async {
    try {
      final history = await _session.api!.fetchRoomMessages(room.id);
      await _session.decryptHistory(room, history);
      if (!_mergeHistory(history)) return;
      notifyListeners();
      if (_session.activeRoomId == room.id && _session.appInForeground) {
        markReadNow();
      }
    } catch (_) {
      // 재연결 직후 갱신 실패는 조용히 넘어간다 — 다음 재연결 때 다시 시도됨.
    }
  }

  /// 검색 결과 등에서 특정 메시지로 바로 스크롤하고 싶을 때 쓴다. 그 메시지가 아직 로드된
  /// 범위 밖(기본 50개보다 오래됨)이면, loadOlderMessages와 같은 방식(before 커서)으로
  /// 찾을 때까지 과거로 여러 페이지 이어서 불러온다 — 서버가 한 번에 최대 200개까지만
  /// 주므로(한 번의 큰 요청으로는 아주 오래된 메시지를 못 찾는다).
  Future<void> ensureMessageLoaded(String messageId) async {
    if (messages.any((m) => m.id == messageId)) return;
    const pageSize = 200;
    const maxPages = 20; // 최대 20*200 = 4000개까지 과거로 훑는다.
    try {
      var cursor = _historyCursor;
      for (var i = 0; i < maxPages; i++) {
        final history = await _session.api!.fetchRoomMessages(
          room.id,
          limit: pageSize,
          before: cursor,
        );
        if (history.isEmpty) break;
        await _session.decryptHistory(room, history);
        if (_mergeHistory(history)) notifyListeners();
        _advanceHistoryCursor(history);
        // 창 밖 부모(outOfWindow)는 페이지의 일부가 아니므로 개수/커서 계산에서 뺀다.
        final inWindow = history.where((m) => !m.outOfWindow).toList();
        if (inWindow.length < pageSize) {
          hasMoreHistory = false;
          break;
        }
        if (messages.any((m) => m.id == messageId)) return;
        cursor = inWindow.first.createdAt;
      }
    } catch (_) {
      // 실패해도 조용히 무시 — 스크롤/하이라이트만 안 될 뿐 방 자체는 정상적으로 보인다.
    }
  }

  Message? _firstMessageOn(DateTime date) {
    for (final m in messages) {
      if (m.createdAt.year == date.year &&
          m.createdAt.month == date.month &&
          m.createdAt.day == date.day) {
        return m;
      }
    }
    return null;
  }

  /// 날짜 알약의 달력에서 특정 날짜를 골랐을 때 쓴다. ensureMessageLoaded와 같은 방식
  /// (before 커서로 과거 페이지를 이어서 요청)으로 그 날짜가 로드될 때까지 과거로 훑고,
  /// 그 날짜의 가장 이른(=구분선이 그려지는) 메시지를 돌려준다. 그 날짜에 메시지가 아예
  /// 없으면(주말이라 대화가 없었다거나) null — 호출부가 안내만 하고 스크롤은 하지 않는다.
  Future<Message?> ensureDateLoaded(DateTime date) async {
    final existing = _firstMessageOn(date);
    if (existing != null) return existing;
    if (messages.isNotEmpty) {
      final oldestLoadedDay = DateTime(
        messages.first.createdAt.year,
        messages.first.createdAt.month,
        messages.first.createdAt.day,
      );
      // 이미 로딩된 범위가 그 날짜보다 과거까지 갔는데도 없으면, 그 날짜엔 메시지가 없는 것.
      if (!oldestLoadedDay.isAfter(date)) return null;
    }

    const pageSize = 200;
    const maxPages = 50; // 날짜 이동은 검색보다 훨씬 과거로도 갈 수 있어 한도를 넉넉히 준다.
    try {
      var cursor = _historyCursor;
      for (var i = 0; i < maxPages; i++) {
        final history = await _session.api!.fetchRoomMessages(
          room.id,
          limit: pageSize,
          before: cursor,
        );
        if (history.isEmpty) break;
        await _session.decryptHistory(room, history);
        if (_mergeHistory(history)) notifyListeners();
        _advanceHistoryCursor(history);
        final inWindow = history.where((m) => !m.outOfWindow).toList();
        final found = _firstMessageOn(date);
        if (found != null) return found;
        if (inWindow.length < pageSize) {
          hasMoreHistory = false;
          break;
        }
        final oldestPageDay = DateTime(
          inWindow.first.createdAt.year,
          inWindow.first.createdAt.month,
          inWindow.first.createdAt.day,
        );
        // 이 페이지가 목표 날짜를 이미 지나쳤는데도 못 찾았으면 그 날짜엔 메시지가 없는 것.
        if (!oldestPageDay.isAfter(date)) break;
        cursor = inWindow.first.createdAt;
      }
    } catch (_) {
      // 실패해도 조용히 무시 — 호출부가 "메시지가 없습니다"와 동일하게 처리한다.
    }
    return _firstMessageOn(date);
  }

  void markReadNow() {
    _session.chatSocket.markRead(room.id);
    if (!room.isSecret) return;
    // 비밀 대화 자동 삭제 타이머는 "상대가 읽은 시점"부터 세므로, 지금 로드돼있는 메시지 중
    // 내가 안 보낸 것들에 대해 읽음 신호를 보낸다(서버가 최초 1회만 처리하므로 중복 호출은
    // 안전하다). 방을 처음 열 때(_load)와 실시간으로 새 메시지를 볼 때(feed) 모두 이 함수를
    // 거치므로 "실제로 화면에 나타난 시점"을 대체로 잘 근사한다.
    for (final m in messages) {
      if (m.senderId == _session.userId) continue;
      if (m.type != MessageType.text &&
          m.type != MessageType.image &&
          m.type != MessageType.file) {
        continue;
      }
      _session.chatSocket.markSecretMessageRead(room.id, m.id);
    }
  }

  Future<void> sendText(String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final payload = await _session.encryptOutgoing(room, trimmed);
    await _session.chatSocket.send(
      roomId: room.id,
      type: 'text',
      text: payload,
    );
  }

  /// 이모티콘 전송 — text 필드에 스티커 id만 실어 보낸다(client/lib/data/stickers.dart 참고).
  /// 파일 업로드가 없어서 sendText와 거의 동일하고, type만 다르다.
  Future<void> sendSticker(String stickerId) async {
    final payload = await _session.encryptOutgoing(room, stickerId);
    await _session.chatSocket.send(
      roomId: room.id,
      type: 'sticker',
      text: payload,
    );
  }

  /// 파일을 서버에 올린다(썸네일 업로드, 비밀 대화면 원본 암호화까지 포함) — 실제 메시지/댓글
  /// 전송(sendUploadedAttachment/postUploadedCommentAttachment)과 분리해서, 첨부한 즉시(보내기를
  /// 누르기 전부터) 입력창에서 업로드를 시작할 수 있게 한다. [originalBytes]/[thumbBytes]는
  /// 호출부(ChatInputBar/CommentInputBar)가 첨부 즉시 한 번만 읽어/생성해서 넘긴다 — 여기서
  /// 다시 읽거나 다시 생성하지 않는다(큰 파일을 두 번 읽지 않기 위함). [onProgress]/
  /// [cancelToken]은 원본 파일 업로드에만 연결한다(썸네일은 작고 빨라서 진행률/취소를 안 건다).
  Future<UploadedAttachment> uploadAttachment(
    File file, {
    required bool isImage,
    required Uint8List originalBytes,
    required Uint8List? thumbBytes,
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    final (thumbnailUrl, thumbnailKey, thumbnailNonce) =
        await _uploadThumbnailIfImage(thumbBytes);

    if (room.isSecret) {
      final encrypted = await secret_crypto.encryptAttachment(originalBytes);
      final tempFile = await _writeTempFile(encrypted.cipherBytes);
      final result = await _session.api!.uploadFile(
        tempFile,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      unawaited(tempFile.delete().catchError((_) => tempFile));
      return UploadedAttachment(
        isImage: isImage,
        url: result.url,
        fileName: 'encrypted',
        size: encrypted.cipherBytes.length,
        mimeType: 'application/octet-stream',
        thumbnailUrl: thumbnailUrl,
        attachmentKey: encrypted.keyBase64,
        attachmentNonce: encrypted.nonceBase64,
        thumbnailKey: thumbnailKey,
        thumbnailNonce: thumbnailNonce,
      );
    }

    final result = await _session.api!.uploadFile(
      file,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
    return UploadedAttachment(
      isImage: isImage,
      url: result.url,
      fileName: result.fileName,
      size: result.size,
      mimeType: result.mimeType,
      thumbnailUrl: thumbnailUrl,
    );
  }

  /// 이미 업로드가 끝난 첨부(uploadAttachment 결과)로 채팅 메시지를 보낸다. [caption]을 같이
  /// 주면(첨부 후 텍스트도 입력한 경우) 그 메시지 하나에 첨부와 텍스트가 함께 실린다. 비밀
  /// 대화면 파일 바이트 자체가 이미 암호화된 채로 올라가 있으므로(서버는 opaque한 바이트로만
  /// 취급), 캡션+원본 파일정보+복호화 키를 메시지 암호문 봉투 안에 함께 넣어 보낸다.
  Future<void> sendUploadedAttachment(
    UploadedAttachment u, {
    String? caption,
  }) async {
    final trimmedCaption = caption?.trim();
    if (room.isSecret) {
      final envelope = await _session.encryptAttachmentPayload(
        room,
        caption: trimmedCaption?.isNotEmpty == true ? trimmedCaption : null,
        fileName: u.fileName,
        fileSize: u.size,
        mimeType: u.mimeType,
        attachmentKey: u.attachmentKey!,
        attachmentNonce: u.attachmentNonce!,
        thumbnailKey: u.thumbnailKey,
        thumbnailNonce: u.thumbnailNonce,
      );
      await _session.chatSocket.send(
        roomId: room.id,
        type: u.isImage ? 'image' : 'file',
        text: envelope,
        fileUrl: u.url,
        fileName: 'encrypted',
        fileSize: u.size,
        mimeType: 'application/octet-stream',
        thumbnailUrl: u.thumbnailUrl,
      );
      return;
    }

    await _session.chatSocket.send(
      roomId: room.id,
      type: u.isImage ? 'image' : 'file',
      text: trimmedCaption?.isNotEmpty == true ? trimmedCaption : null,
      fileUrl: u.url,
      fileName: u.fileName,
      fileSize: u.size,
      mimeType: u.mimeType,
      thumbnailUrl: u.thumbnailUrl,
    );
  }

  /// 이미 올라간 이미지 여러 장을 **한 메시지**로 보낸다(채팅 버블에 격자로 보인다).
  /// 비밀 대화는 첨부마다 복호화 키가 따로라 봉투에 한 개만 담을 수 있어서, 거기서는
  /// 예전처럼 한 장씩 따로 보낸다(sendUploadedAttachment).
  Future<void> sendUploadedAttachments(
    List<UploadedAttachment> items, {
    String? caption,
  }) async {
    if (items.isEmpty) return;
    if (items.length == 1 || room.isSecret) {
      for (var i = 0; i < items.length; i++) {
        await sendUploadedAttachment(
          items[i],
          caption: i == 0 ? caption : null,
        );
      }
      return;
    }
    final trimmed = caption?.trim();
    await _session.chatSocket.send(
      roomId: room.id,
      type: 'image',
      text: trimmed?.isNotEmpty == true ? trimmed : null,
      attachments: [
        for (final u in items)
          {
            'kind': u.isImage ? 'image' : 'file',
            'fileUrl': u.url,
            'fileName': u.fileName,
            'fileSize': u.size,
            'mimeType': ?u.mimeType,
            'thumbnailUrl': ?u.thumbnailUrl,
          },
      ],
    );
  }

  /// 이미지 첨부일 때만(=[thumbBytes]가 있을 때만) 채팅 버블 미리보기용 축소 썸네일을
  /// 올린다. 비밀 대화면 원본과 마찬가지로 자기만의 랜덤 키/nonce로 암호화해서 올리고(원본
  /// 키를 재사용하지 않음), 평문 방이면 그대로 올린다. 이미지가 아니거나 썸네일 생성에
  /// 실패했으면([thumbBytes] == null) 전부 null — 버블은 원본(fileUrl)을 그대로 보여주게 된다.
  Future<(String?, String?, String?)> _uploadThumbnailIfImage(
    Uint8List? thumbBytes,
  ) async {
    if (thumbBytes == null) return (null, null, null);

    if (room.isSecret) {
      final encrypted = await secret_crypto.encryptAttachment(thumbBytes);
      final tempFile = await _writeTempFile(encrypted.cipherBytes);
      final result = await _session.api!.uploadFile(tempFile);
      unawaited(tempFile.delete().catchError((_) => tempFile));
      return (result.url, encrypted.keyBase64, encrypted.nonceBase64);
    }

    final tempFile = await _writeTempFile(thumbBytes);
    final result = await _session.api!.uploadFile(tempFile);
    unawaited(tempFile.delete().catchError((_) => tempFile));
    return (result.url, null, null);
  }

  /// 암호화한 첨부 바이트를 기존 uploadFile(File)에 그대로 태우기 위한 임시 파일. 썸네일
  /// 업로드에도 재사용한다(평문 썸네일도 File 형태로 올려야 uploadFile을 그대로 쓸 수 있어서).
  Future<File> _writeTempFile(Uint8List bytes) async {
    final dir = await getTemporaryDirectory();
    final file = File(
      '${dir.path}/upload_${DateTime.now().microsecondsSinceEpoch}.bin',
    );
    return file.writeAsBytes(bytes);
  }

  @override
  void dispose() {
    _readSub?.cancel();
    super.dispose();
  }
}
