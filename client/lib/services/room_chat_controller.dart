import 'dart:async';

import 'package:cross_file/cross_file.dart';
import 'package:flutter/foundation.dart';

import '../models/board_category.dart';
import '../models/call_card.dart';
import '../models/comment.dart';
import '../models/mention.dart';
import '../models/message.dart';
import '../models/message_reaction.dart';
import '../models/poll.dart';
import '../models/room.dart';
import '../models/text_format.dart';
import '../models/uploaded_attachment.dart';
import 'api_client.dart' show ApiClient, ApiException, UploadCancelToken;
import 'chat_draft_store.dart' show ChatDraft;
import 'connection_errors.dart';
import 'message_outbox.dart' show OutboxFile, OutboxKind, newClientId;
import 'file_type_utils.dart';
import 'image_thumbnail.dart';
import 'photo_quality.dart';
import 'memory_file.dart';
import 'secret_chat_crypto.dart' as secret_crypto;
import 'secret_key_store.dart' show SecretCachedTextInfo;
import 'secret_session_manager.dart' show SecretTextPlace;
import 'session.dart';
import 'typing_gate.dart';

// UploadedAttachment는 예약 메시지(모델·ApiClient)도 써서 모델로 옮겼다 — 예전처럼 이 파일만
// import해도 쓸 수 있게 다시 내보낸다.
export '../models/uploaded_attachment.dart';
import '../l10n/tr.dart';

/// 암호화한 첨부나 썸네일 바이트를 uploadFile(XFile)에 그대로 태우는 메모리 파일 — 예전엔 임시
/// 폴더에 파일로 썼지만 웹에는 임시 폴더가 없고, 메모리에서 바로 올리면 이름이 겹쳐 서로 덮어쓰는
/// 일(Windows의 낮은 시계 해상도로 같은 이름이 나오던 문제)도 없다.
XFile _uploadBytesFile(Uint8List bytes) => bytesAsFile(bytes, 'upload.bin');

/// 평문 첨부 하나를 올린다(비밀 대화 암호화 없이) — [thumbBytes]가 있으면(이미지) 채팅 버블
/// 미리보기용 축소 썸네일을 먼저 올리고, 그다음 원본을 올린다. [onProgress]/[cancelToken]은 원본
/// 업로드에만 건다(썸네일은 작고 빨라서).
Future<UploadedAttachment> _uploadPlainAttachment(
  ApiClient api,
  XFile file, {
  required bool isImage,
  Uint8List? thumbBytes,
  void Function(int sent, int total)? onProgress,
  UploadCancelToken? cancelToken,
}) async {
  String? thumbnailUrl;
  if (thumbBytes != null) {
    final tempFile = _uploadBytesFile(thumbBytes);
    thumbnailUrl = (await api.uploadFile(tempFile)).url;
  }
  final result = await api.uploadFile(
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

/// 비밀 대화 첨부 하나를 올린다 — 원본(과 [thumbBytes]가 있으면 버블 미리보기용 축소 썸네일)을 저마다의 랜덤 키/nonce로 암호화해
/// 올린다(썸네일이 원본 키를 다시 쓰지 않는다). 서버에는 암호문만 가고, 복호화 키와 원래 이름([name])·형식은 돌려준 값에 담겨
/// 메시지 봉투(암호문) 안으로 들어간다(Session.encryptAttachmentPayload). 썸네일이 없으면(이미지가 아니거나 만들지 못함) 썸네일
/// 칸은 비고, 버블은 원본을 그대로 보여 준다. 입력칸(RoomChatController.uploadAttachment)과 보내기 대기열(연결되면 올리는 비밀
/// 대화의 사진·파일 — Session._deliverOutbox)이 같이 쓴다. [onProgress]/[cancelToken]은 원본 업로드에만 건다.
Future<UploadedAttachment> uploadSecretBytes(
  ApiClient api,
  Uint8List bytes, {
  required bool isImage,
  required String name,
  String? mimeType,
  Uint8List? thumbBytes,
  void Function(int sent, int total)? onProgress,
  UploadCancelToken? cancelToken,
}) async {
  String? thumbnailUrl;
  String? thumbnailKey;
  String? thumbnailNonce;
  if (thumbBytes != null) {
    final thumb = await secret_crypto.encryptAttachment(thumbBytes);
    thumbnailUrl = (await api.uploadFile(
      _uploadBytesFile(thumb.cipherBytes),
    )).url;
    thumbnailKey = thumb.keyBase64;
    thumbnailNonce = thumb.nonceBase64;
  }
  final encrypted = await secret_crypto.encryptAttachment(bytes);
  final result = await api.uploadFile(
    _uploadBytesFile(encrypted.cipherBytes),
    onProgress: onProgress,
    cancelToken: cancelToken,
  );
  return UploadedAttachment(
    isImage: isImage,
    url: result.url,
    // 봉투 안에 들어갈 원래 이름·형식 — 서버에 보내는 칸은 늘 'encrypted'·application/octet-stream이다(보내는 쪽이 채운다).
    // 예전엔 여기에 'encrypted'를 담아 받는 사람에게도 파일 이름이 "encrypted"로 보였다.
    fileName: name,
    size: encrypted.cipherBytes.length,
    mimeType: mimeType,
    thumbnailUrl: thumbnailUrl,
    attachmentKey: encrypted.keyBase64,
    attachmentNonce: encrypted.nonceBase64,
    thumbnailKey: thumbnailKey,
    thumbnailNonce: thumbnailNonce,
  );
}

/// 비밀 대화의 올린 첨부를 보내기 대기열 본문의 `secretAttachment`로 — 보낼 때 봉투로 암호화한다(Session._deliverOutbox). 평문
/// 이름·키가 들어 있어 대기열은 이 일을 메모리에만 둔다(비밀 대화 — 저장하지 않음).
Map<String, dynamic> secretAttachmentPayload(UploadedAttachment u) => {
  'url': u.url,
  'fileName': u.fileName,
  'fileSize': u.size,
  'mimeType': ?u.mimeType,
  'thumbnailUrl': ?u.thumbnailUrl,
  'attachmentKey': u.attachmentKey,
  'attachmentNonce': u.attachmentNonce,
  'thumbnailKey': ?u.thumbnailKey,
  'thumbnailNonce': ?u.thumbnailNonce,
};

/// 방과 무관하게 로컬 파일 하나를 채팅 입력칸과 같은 방식(평문)으로 올린다 — 이미지면(안 주면
/// 확장자로 판별) 축소 썸네일도 만들어 같이 올린다. 아직 보낼 방이 정해지지 않은 화면(예약
/// 메시지 편집)이 Session.uploadAttachments로 쓴다. 비밀 대화 첨부는 RoomChatController로 올린다.
Future<UploadedAttachment> uploadPlainFile(
  ApiClient api,
  XFile file, {
  bool? isImage,
  void Function(int sent, int total)? onProgress,
  UploadCancelToken? cancelToken,
}) async {
  final image = isImage ?? looksLikeImagePath(file.name);
  // 원본을 메모리로 읽는 건 썸네일을 만들 때(이미지)뿐 — 큰 일반 파일은 그대로 스트리밍해서 올린다.
  final thumbBytes = image
      ? await generateThumbnail(await file.readAsBytes())
      : null;
  return _uploadPlainAttachment(
    api,
    file,
    isImage: image,
    thumbBytes: thumbBytes,
    onProgress: onProgress,
    cancelToken: cancelToken,
  );
}

/// 여러 파일을 [uploadPlainFile]로 순서대로 올린다(onProgress/실패 규칙은 uploadLocalFiles와 같다).
Future<List<UploadedAttachment>> uploadPlainFiles(
  ApiClient api,
  List<XFile> files, {
  void Function(int index, int sent, int total)? onProgress,
  UploadCancelToken? cancelToken,
}) => _uploadInOrder(
  files,
  (file, progress) => uploadPlainFile(
    api,
    file,
    onProgress: progress,
    cancelToken: cancelToken,
  ),
  onProgress: onProgress,
);

/// 파일을 하나씩 순서대로 [uploadOne]으로 올린다. [onProgress]는 지금 올리는 파일의 순번(0부터)과
/// 그 파일의 진행 바이트를 알려준다. 하나라도 실패하면 그 예외가 그대로 나간다(이미 올라간 앞
/// 파일들은 서버에 남지만 어디에도 연결되지 않는다).
Future<List<UploadedAttachment>> _uploadInOrder(
  List<XFile> files,
  Future<UploadedAttachment> Function(
    XFile file,
    void Function(int sent, int total)? onProgress,
  )
  uploadOne, {
  void Function(int index, int sent, int total)? onProgress,
}) async {
  final uploaded = <UploadedAttachment>[];
  for (var i = 0; i < files.length; i++) {
    uploaded.add(
      await uploadOne(
        files[i],
        onProgress == null ? null : (sent, total) => onProgress(i, sent, total),
      ),
    );
  }
  return uploaded;
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

  /// 대화 목록을 다시 그리게 하는 알림 — 한글을 조합하며 빠르게 치는 동안에는 잠깐 모아 둔다
  /// (typing_gate.dart 참고). 방이 사라져(나가기·내보내짐·삭제) 정리된 뒤 늦게 끝난 요청이
  /// 다시 그리려 하면 조용히 무시한다.
  @override
  void notifyListeners() {
    if (_disposed) return;
    TypingGate.instance.run(this, super.notifyListeners);
  }

  final Session _session;
  Session get session => _session;
  final Room room;
  final List<Message> messages = [];

  /// 입력칸에 쓰다 만 글(서식·멘션 포함, 임시 저장) — 입력칸(ChatInputBar)이 쓰는 동안·사라질 때 맡겨 두고 다시 열 때 꺼낸다.
  /// 실제로는 Session의 [ChatDraftStore]에 방마다 들어 있어서 다른 방에 갔다 와도, 앱을 껐다 켜도 남는다(비밀 대화는 메모리에만).
  /// 비어 있으면 null.
  ChatDraft? get draft => _session.chatDrafts.get(room.id);
  set draft(ChatDraft? value) =>
      _session.chatDrafts.put(room.id, value, persist: !room.isSecret);
  bool loading = true;
  String? error;

  /// 서버에 닿지 않아 이 기기에 저장해 둔 최근 메시지를 보여 주는 중인지(offline_cache.dart) — 다시 연결되면 [refresh]가 서버 것으로 맞춘다.
  bool fromCache = false;
  StreamSubscription? _readSub;
  bool _disposed = false;

  /// 보드 뷰 상단 "고정된 게시글"(게시글 작성 시각 최신순) — [loadPinnedPosts]로 채우고, 이후엔
  /// 고정/해제·수정·삭제 브로드캐스트(applyEdit/applyDelete)로 그 자리에서 맞춘다. 타임라인
  /// ([messages])에 이미 있는 게시글이면 같은 인스턴스를 써서 댓글·수정이 양쪽에 함께 보인다.
  final List<Message> pinnedPosts = [];

  /// [pinnedPosts]를 한 번이라도 받아왔는지 — 받기 전엔 실시간 고정 이벤트로 목록을 만들지 않는다.
  bool pinnedPostsLoaded = false;

  /// 보드 위 "필독 안 읽음" — 이 보드에서 내가 아직 안 읽은 필독 게시글(최근 지정순). [loadUnreadMustRead]로 채우고,
  /// 게시글을 열거나([markPostRead]) 필독이 바뀌면(applyEdit) 맞춘다. 받기 전엔 null.
  List<UnreadMustRead>? unreadMustRead;

  final _postReads = StreamController<String>.broadcast();

  /// 이 방의 게시글을 누가 처음 읽었다(post:read) — 게시글 id. 열려 있는 상세가 읽음 확인을 다시 받는다.
  Stream<String> get postReads => _postReads.stream;

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
      final generation = _secretCacheGeneration;
      final history = await _session.api!.fetchRoomMessages(
        room.id,
        limit: _pageSize,
      );
      if (_disposed) return;
      await _session.decryptHistory(room, history);
      await _reconcileSecretPage(
        history,
        before: null,
        limit: _pageSize,
        sinceGeneration: generation,
      );
      _mergeHistory(history);
      _advanceHistoryCursor(history);
      // 창 밖 부모(outOfWindow)는 페이지 크기 판정에서도 빼야 "끝에 도달했다"를 놓치지 않는다.
      if (history.where((m) => !m.outOfWindow).length < _pageSize) {
        hasMoreHistory = false;
      }
    } catch (e) {
      // 서버에 닿지 않으면 저장해 둔 최근 메시지로(비밀 대화는 저장하지 않는다).
      final cached = await _session.cachedMessages(room);
      if (_disposed) return;
      if (cached.isEmpty) {
        error = e.toString();
      } else {
        _mergeHistory(cached);
        // 위로 넘기면 이 기기 메시지 DB에서 더 오래된 기록을 꺼낸다(loadOlderMessages).
        _advanceHistoryCursor(cached);
        fromCache = true;
      }
    }
    loading = false;
    notifyListeners();
    markReadNow();
  }

  /// 처음 불러오기가 실패한 방을 다시 불러온다(보드의 "다시 시도"). 컨트롤러는 세션 내내 캐싱되고
  /// refresh는 과거 페이지 커서를 잡지 않아서, 이게 없으면 다시 열어도 빈 목록에 머문다.
  Future<void> retryLoad() async {
    if (loading) return;
    loading = true;
    error = null;
    notifyListeners();
    await _load();
  }

  /// 채팅방 맨 위 근처까지 스크롤했을 때(chat_panel.dart) 그보다 오래된 메시지를 더
  /// 불러와서 앞쪽에 이어붙인다. 이미 불러오는 중이거나 더 가져올 게 없으면 아무것도 안 한다.
  Future<void> loadOlderMessages() async {
    final cursor = _historyCursor;
    if (loadingMore || !hasMoreHistory || cursor == null) return;
    loadingMore = true;
    notifyListeners();
    try {
      final generation = _secretCacheGeneration;
      final older = await _session.api!.fetchRoomMessages(
        room.id,
        limit: _pageSize,
        before: cursor,
      );
      if (older.where((m) => !m.outOfWindow).length < _pageSize) {
        hasMoreHistory = false;
      }
      await _session.decryptHistory(room, older);
      // 빈 페이지여도 맞춘다 — "그보다 오래된 메시지가 하나도 없다"는 것도 서버의 답이다.
      await _reconcileSecretPage(
        older,
        before: cursor,
        limit: _pageSize,
        sinceGeneration: generation,
      );
      if (older.isNotEmpty) {
        _mergeHistory(older);
        _advanceHistoryCursor(older);
      }
    } catch (_) {
      // 서버에 닿지 않으면 이 기기 메시지 DB에 쌓아 둔 더 오래된 기록을 보여 준다(비밀 대화는 없다). 그것도 없으면 조용히
      // 넘어간다 — 계속 스크롤하면 다시 시도된다.
      final local = await _session.cachedOlderMessages(room, cursor, _pageSize);
      if (!_disposed && local.isNotEmpty) {
        _mergeHistory(local);
        _advanceHistoryCursor(local);
        fromCache = true;
      }
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
    // 고정 목록에만 따로 있던 옛 게시글 — 타임라인에 들어올 때도 그 인스턴스를 그대로 쓴다(게시글
    // 상세가 그 인스턴스를 들고 있을 수 있어서, 바꿔 끼우면 그 뒤 댓글·수정이 상세에 안 보인다).
    final pinnedOnly = {
      for (final p in pinnedPosts)
        if (!byId.containsKey(p.id)) p.id: p,
    };
    final newMessages = <Message>[];
    final newCommentEntries = <Message>[];
    var changed = false;

    for (final incoming in history) {
      final existing = byId[incoming.id];
      if (existing == null) {
        final pinned = pinnedOnly.remove(incoming.id);
        if (pinned != null) {
          _syncPostState(pinned, incoming);
          _syncPinned(pinned); // 그 사이 고정이 풀렸거나 지워졌으면 고정 목록에서 뺀다.
          _mergeComments(pinned, incoming.comments);
          newMessages.add(pinned);
          newCommentEntries.addAll(pinned.comments.map(Message.commentEntry));
          continue;
        }
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
      // 게시글은 고정/수정/삭제가 보드에 바로 보이는 상태라, 끊긴 동안 놓친 변경도 따라잡는다.
      if (incoming.isPost && _syncPostState(existing, incoming)) {
        _syncPinned(existing);
        changed = true;
      }
      // 투표도 끊긴 동안 놓친 표·마감·삭제를 따라잡는다(REST는 내 기준 값을 준다).
      if (incoming.isPoll && _syncPollState(existing, incoming)) changed = true;
      // 공감도 끊긴 동안 놓친 것을 따라잡는다(목록 응답에는 늘 전체 공감이 실려 온다).
      if (!sameReactions(existing.reactions, incoming.reactions)) {
        existing.reactions = incoming.reactions;
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

  /// 비밀 대화 평문 캐시의 지금 저장 순번 — 히스토리를 요청하기 직전에 잡아서 [_reconcileSecretPage]에 넘긴다.
  int get _secretCacheGeneration =>
      _session.secretSessionManager?.textCacheGeneration ?? 0;

  /// 비밀 대화: 방금 받은 히스토리 한 페이지([page] — [before]·[limit]으로 요청한 것)로 이 기기의 평문
  /// 캐시와 화면을 서버에 맞춘다(S34). 서버가 자동 삭제·삭제한 메시지는 그 순간 연결돼 있지 않았으면
  /// 알림(message:expired/deleted)이 다시 오지 않아서, 이번 요청이 실제로 훑은 범위 안인데 응답에 없는
  /// 항목의 평문을 지우고(SecretKeyStore.reconcileHistoryPage) 화면에서도 뺀다. 지운 것으로 표시돼 온
  /// (소프트 삭제) 메시지·댓글도 화면을 맞춘다. [sinceGeneration]은 요청 직전에 잡은 저장 순번 — 그 뒤에
  /// 저장된 항목(요청보다 늦게 도착한 메시지일 수 있다)은 이번 응답에 없어도 그대로 둔다.
  Future<void> _reconcileSecretPage(
    List<Message> page, {
    required DateTime? before,
    required int limit,
    required int sinceGeneration,
  }) async {
    final manager = _session.secretSessionManager;
    if (!room.isSecret || manager == null) return;
    final removed = await manager.reconcileHistoryPage(
      roomId: room.id,
      page: page,
      before: before,
      limit: limit,
      sinceGeneration: sinceGeneration,
    );
    applySecretCacheRemovals(page, removed);
  }

  /// 비밀 대화: 히스토리 한 페이지([page])로 서버와 맞춰 본 결과 평문 캐시에서 지운 항목([removed])을 화면에도
  /// 반영한다 — 이 화면이 받은 페이지([_reconcileSecretPage])뿐 아니라, Session의 뒷정리가 이 화면 없이 받은
  /// 페이지(Session.syncSecretTextCaches)로 맞춘 결과도 여기로 온다.
  void applySecretCacheRemovals(
    List<Message> page,
    List<SecretCachedTextInfo> removed,
  ) {
    if (_disposed || !room.isSecret) return;
    final presentIds = {for (final m in page) m.id};
    final goneMessageIds = {
      for (final r in removed)
        if (!r.isComment && !presentIds.contains(r.id)) r.id,
    };
    // 서버에서 완전히 없어진 메시지 — 자동 삭제 만료와 같이 댓글째 화면에서 뺀다.
    for (final id in goneMessageIds) {
      applyExpire(id);
    }
    // 원본은 남았는데 댓글만 없어졌으면 지워진 댓글로 보인다.
    for (final r in removed) {
      final parentId = r.parentId;
      if (parentId == null || goneMessageIds.contains(parentId)) continue;
      if (_findComment(r.id)?.deleted == false) applyCommentDelete(r.id);
    }
    // 끊긴 동안 놓친 삭제(소프트 삭제) — 이미 화면에 있는 메시지·댓글에도 반영한다(_mergeHistory는 안 바꾼다).
    for (final m in page) {
      if (m.deleted && _instancesOf(m.id).any((x) => !x.deleted)) {
        applyDelete(m.id);
      }
      for (final c in m.comments) {
        if (c.deleted && _findComment(c.id)?.deleted == false) {
          applyCommentDelete(c.id);
        }
      }
    }
  }

  /// Session이 이 방으로 들어온 실시간 메시지를 라우팅할 때 호출한다.
  void feed(Message m) {
    // 실시간 새 글엔 "내가 읽었는지"가 없다 — 남의 보드 게시글이면 안 읽은 것, 내 글이면 읽은 것.
    if (m.isPost && m.readByMe == null && room.isBoard) {
      m.readByMe = m.senderId != null && m.senderId == _session.userId;
      if (m.isMustRead && m.readByMe == false && unreadMustRead != null) {
        unreadMustRead = [(id: m.id, title: m.title ?? ''), ...unreadMustRead!];
      }
    }
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
    if (idx == -1) {
      // 타임라인엔 아직 없는 옛 게시글이라도 고정 목록에 있으면 그 댓글 목록은 맞춰 둔다
      // (게시글 상세가 그 인스턴스의 comments를 그대로 그린다).
      final pinned = pinnedPosts.where((p) => p.id == c.messageId).firstOrNull;
      if (pinned == null || pinned.comments.any((x) => x.id == c.id)) return;
      pinned.comments.add(c);
      notifyListeners();
      return;
    }
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
  /// 여기서 낙관적으로 먼저 추가할 필요가 없다). 서버에 닿지 않으면 보내기 대기열에 넣어 연결되면 단다([_postCommentOrQueue]).
  /// [format]은 [text]의 글자 서식 — [text]는 이미 앞뒤 공백을 뗀 것이어야 위치가 맞는다
  /// (RichTextEditingController.formatted). 비밀 대화는 서식 없이 보낸다.
  Future<void> postComment(
    String messageId,
    String text, {
    List<TextFormatRun>? format,
    List<Mention>? mentions,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final plain = !room.isSecret && trimmed == text;
    await _postCommentOrQueue(messageId, {
      'type': 'text',
      'text': trimmed,
      'textFormat': ?(plain ? textFormatToJson(format) : null),
      'mentions': ?(plain ? mentionsToJson(mentions) : null),
    }, preview: tr('댓글 · {text}', {'text': trimmed}));
  }

  /// 댓글로 이모티콘을 단다 — sendSticker와 동일한 방식(파일 업로드 없이 id만 전송).
  Future<void> postCommentSticker(String messageId, String stickerId) =>
      _postCommentOrQueue(messageId, {
        'type': 'sticker',
        'text': stickerId,
      }, preview: tr('댓글 · 이모티콘'));

  /// 글·이모티콘 댓글을 임시 id를 붙여 단다(Session.sendCommentPayload — 비밀 대화면 거기서 암호화). 서버에 닿지 않는 것이
  /// 확인됐거나(Session.knownOffline) 연결 문제로 실패하면 같은 임시 id로 보내기 대기열에 넣는다 — 응답만 못 받고 처음 것이
  /// 들어갔어도 서버가 같은 임시 id면 새로 만들지 않는다(server/src/comments.js). 비밀 대화의 것은 메모리에만(평문).
  Future<void> _postCommentOrQueue(
    String messageId,
    Map<String, dynamic> body, {
    required String preview,
  }) async {
    final clientId = newClientId();
    final payload = {...body, 'messageId': messageId, 'clientId': clientId};
    void queue() => _session.outbox.submitAction(
      roomId: room.id,
      kind: OutboxKind.comment,
      payload: payload,
      preview: preview,
      secret: room.isSecret,
      clientId: clientId,
    );

    if (_session.knownOffline) return queue();
    try {
      await _session.sendCommentPayload(room, payload);
    } catch (e) {
      if (!isConnectionError(e)) rethrow;
      queue();
    }
  }

  /// 이미 업로드가 끝난 첨부(uploadAttachment 결과)로 댓글을 단다. [caption]을 같이 주면(첨부
  /// 후 텍스트도 입력한 경우) 그 댓글 하나에 첨부와 텍스트가 함께 실린다.
  Future<void> postUploadedCommentAttachment(
    String messageId,
    UploadedAttachment u, {
    String? caption,
    List<TextFormatRun>? captionFormat,
    List<Mention>? captionMentions,
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
        place: SecretTextPlace.comment(parentId: messageId),
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
      textFormat: trimmedCaption == caption ? captionFormat : null,
      mentions: trimmedCaption == caption ? captionMentions : null,
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
  Future<void> editComment(
    String commentId,
    String text, {
    List<TextFormatRun>? format,
    List<Mention>? mentions,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final payload = await _session.encryptOutgoing(
      room,
      trimmed,
      place: SecretTextPlace.comment(
        parentId: _findComment(commentId)?.messageId,
        editOf: commentId,
      ),
    );
    await _session.api!.editComment(
      commentId,
      payload!,
      textFormat: room.isSecret || trimmed != text ? null : format,
      mentions: room.isSecret ? null : (trimmed != text ? const [] : mentions),
    );
  }

  /// 댓글을 삭제한다(본인, 작성 5분 이내만 서버가 허용). 실제 반영은
  /// comment:deleted 브로드캐스트(applyCommentDelete)로 이뤄진다.
  Future<void> deleteComment(String commentId) =>
      _session.api!.deleteComment(commentId);

  /// Session이 comment:edited 브로드캐스트를 라우팅할 때 호출한다. 합성 타임라인 항목의
  /// asComment와 원본 메시지의 comments 리스트 항목은 같은 Comment 인스턴스를 공유하므로
  /// (addComment/_mergeHistory 참고), 이 인스턴스 하나만 찾아 그 자리에서 바꾸면 양쪽에 함께 반영된다.
  void applyCommentEdit(Comment edited) {
    final target = _findComment(edited.id);
    if (target == null) return;
    target.text = edited.text;
    target.textFormat = edited.textFormat;
    target.mentions = edited.mentions;
    target.editedAt = edited.editedAt;
    notifyListeners();
  }

  /// Session이 comment:deleted 브로드캐스트를 라우팅할 때 호출한다. 비밀 대화 평문 캐시는 Session이
  /// 이 방 화면이 없어도 지운다(세션의 comment:deleted 처리) — 여기서는 화면만 맞춘다.
  void applyCommentDelete(String commentId) {
    final target = _findComment(commentId);
    if (target == null) return;
    target.deleted = true;
    notifyListeners();
  }

  /// 타임라인의 댓글 합성 항목에서 찾고, 없으면 고정 목록에만 있는 옛 게시글의 댓글에서 찾는다.
  Comment? _findComment(String commentId) {
    final entry = _findCommentEntry(commentId);
    if (entry != null) return entry.asComment;
    for (final p in pinnedPosts) {
      for (final c in p.comments) {
        if (c.id == commentId) return c;
      }
    }
    return null;
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
  /// message:edited 브로드캐스트(applyEdit)로 이뤄진다. 연결이 없거나 연결 문제로 실패하면 화면에 먼저 고쳐 보이고 보내기
  /// 대기열에 넣어 연결되면 반영한다(비밀 대화는 평문이라 메모리에만 — 보낼 때 암호화).
  Future<void> editMessage(
    String messageId,
    String text, {
    List<TextFormatRun>? format,
    List<Mention>? mentions,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    final formatJson = room.isSecret || trimmed != text
        ? null
        : textFormatToJson(format);
    final mentionsJson = room.isSecret
        ? null
        : (trimmed != text ? const <Object?>[] : mentionsToJson(mentions));
    void queue() {
      _applyLocalEdit(
        messageId,
        trimmed,
        format: formatJson == null ? null : format,
      );
      _session.outbox.submitAction(
        roomId: room.id,
        kind: OutboxKind.edit,
        payload: {
          'messageId': messageId,
          'text': trimmed,
          'textFormat': ?formatJson,
          'mentions': ?mentionsJson,
        },
        preview: tr('메시지 수정 · {text}', {'text': trimmed}),
        secret: room.isSecret,
      );
    }

    // 서버에 닿지 않는 것이 확인됐으면(Session.knownOffline) 기다리지 않고 바로 대기열로.
    if (_session.knownOffline) return queue();
    try {
      await _sendEdit(messageId, text, trimmed, format, mentions);
    } catch (e) {
      if (!isConnectionError(e)) rethrow;
      queue();
    }
  }

  /// 고친 글을 화면(과 이 기기 메시지 DB)에 먼저 반영한다 — 대기열이 서버에 보내면 message:edited가 다시 맞춘다.
  void _applyLocalEdit(
    String messageId,
    String text, {
    List<TextFormatRun>? format,
  }) {
    for (final m in _instancesOf(messageId)) {
      m.text = text;
      m.textFormat = format;
      m.editedAt = DateTime.now();
    }
    if (!room.isSecret) {
      _session.offlineCache.updateMessage(
        messageId,
        (raw) => {
          ...raw,
          'text': text,
          'editedAt': DateTime.now().millisecondsSinceEpoch,
        },
      );
    }
    notifyListeners();
  }

  Future<void> _sendEdit(
    String messageId,
    String text,
    String trimmed,
    List<TextFormatRun>? format,
    List<Mention>? mentions,
  ) async {
    final payload = await _session.encryptOutgoing(
      room,
      trimmed,
      place: SecretTextPlace.message(editOf: messageId),
    );
    await _session.api!.editMessage(
      messageId,
      payload!,
      textFormat: room.isSecret || trimmed != text ? null : format,
      mentions: room.isSecret ? null : (trimmed != text ? const [] : mentions),
    );
  }

  /// 사진·파일 메시지를 수정한다 — 설명글(빈 문자열이면 지운다)과 [removeAttachmentIds](지울 첨부 id)를
  /// 함께 고친다. 첨부를 **더하지는** 못 한다(잔디처럼 삭제만). 글 메시지와 달리 글이 비어도 보낸다 —
  /// 첨부를 다 지우는데 글도 없으면 서버가 거절한다(메시지를 삭제하라는 뜻, 화면이 먼저 묻는다). 비밀
  /// 대화의 사진·파일은 서버가 못 고쳐서 화면이 수정 자체를 막는다. 반영은 message:edited(applyEdit).
  /// 서버에 닿지 않으면 글 메시지 고치기([editMessage])처럼 화면(과 이 기기 메시지 DB)에 먼저 고쳐 보이고(설명·지운 첨부) 보내기
  /// 대기열에 넣어 연결되면 반영한다.
  Future<void> editMediaMessage(
    String messageId,
    String text, {
    List<TextFormatRun>? format,
    List<Mention>? mentions,
    List<String> removeAttachmentIds = const [],
  }) async {
    final trimmed = text.trim();
    final sameText = trimmed.isNotEmpty && trimmed == text;
    final formatJson = sameText ? textFormatToJson(format) : null;
    void queue() {
      _applyLocalMediaEdit(
        messageId,
        trimmed,
        format: formatJson == null ? null : format,
        removeAttachmentIds: removeAttachmentIds,
      );
      _session.outbox.submitAction(
        roomId: room.id,
        kind: OutboxKind.edit,
        payload: {
          'messageId': messageId,
          'text': trimmed,
          'textFormat': ?formatJson,
          'mentions': (sameText ? mentionsToJson(mentions) : null) ?? const [],
          if (removeAttachmentIds.isNotEmpty)
            'removeAttachmentIds': removeAttachmentIds,
        },
        preview: trimmed.isEmpty
            ? tr('사진·파일 메시지 수정')
            : tr('메시지 수정 · {text}', {'text': trimmed}),
      );
    }

    // 비밀 대화의 사진·파일은 고칠 수 없다(화면이 막는다) — 대기열에 넣지 않고 서버가 거절하게 둔다.
    if (_session.knownOffline && !room.isSecret) return queue();
    try {
      await _session.api!.editMessage(
        messageId,
        trimmed,
        textFormat: sameText ? format : null,
        mentions: sameText ? mentions : const [],
        removeAttachmentIds: removeAttachmentIds,
      );
    } catch (e) {
      if (room.isSecret || !isConnectionError(e)) rethrow;
      queue();
    }
  }

  /// 사진·파일 메시지의 고친 설명과 지운 첨부를 화면(과 이 기기 메시지 DB)에 먼저 반영한다 — 대기열이 서버에 보내면 message:edited가
  /// 다시 맞춘다(첨부 하나짜리 옛 메시지의 파일 칸처럼 서버가 바꾸는 모양도 그때 맞춰진다).
  void _applyLocalMediaEdit(
    String messageId,
    String text, {
    List<TextFormatRun>? format,
    List<String> removeAttachmentIds = const [],
  }) {
    final removed = removeAttachmentIds.toSet();
    for (final m in _instancesOf(messageId)) {
      m.text = text.isEmpty ? null : text;
      m.textFormat = format;
      m.editedAt = DateTime.now();
      if (removed.isNotEmpty) {
        m.attachments = [
          for (final a in m.attachments)
            if (!removed.contains(a.id)) a,
        ];
      }
    }
    _session.offlineCache.updateMessage(messageId, (raw) {
      final attachments = raw['attachments'];
      return {
        ...raw,
        'text': text.isEmpty ? null : text,
        'editedAt': DateTime.now().millisecondsSinceEpoch,
        if (removed.isNotEmpty && attachments is List)
          'attachments': [
            for (final a in attachments)
              if (a is! Map || !removed.contains(a['id'])) a,
          ],
      };
    });
    notifyListeners();
  }

  /// 메시지를 삭제한다(본인, 작성 5분 이내만 서버가 허용). 실제 반영은
  /// message:deleted 브로드캐스트(applyDelete)로 이뤄진다. 연결이 없거나 연결 문제로 실패하면 화면에서 먼저 지우고 보내기
  /// 대기열에 넣어 연결되면 반영한다(서버가 거절하면 대기열에 이유가 남고, 버리면 서버 것으로 되돌린다).
  Future<void> deleteMessage(String messageId) async {
    void queue() {
      applyDelete(messageId);
      if (!room.isSecret) {
        _session.offlineCache.updateMessage(
          messageId,
          (raw) => {
            ...raw,
            'deleted': true,
            'text': null,
            'attachments': const [],
          },
        );
      }
      _session.outbox.submitAction(
        roomId: room.id,
        kind: OutboxKind.delete,
        payload: {'messageId': messageId},
        preview: tr('메시지 삭제'),
      );
    }

    // 서버에 닿지 않는 것이 확인됐으면(Session.knownOffline) 기다리지 않고 바로 대기열로.
    if (_session.knownOffline) return queue();
    try {
      await _session.api!.deleteMessage(messageId);
    } catch (e) {
      if (!isConnectionError(e)) rethrow;
      queue();
    }
  }

  /// Session이 message:edited 브로드캐스트를 라우팅할 때 호출한다. 게시글의 제목·고정 상태도
  /// 이 이벤트로 오므로(고정/해제도 message:edited) 함께 반영하고 고정 목록을 맞춘다.
  void applyEdit(Message edited) {
    final targets = _instancesOf(edited.id);
    if (targets.isEmpty) {
      // 아직 안 불러온 옛 게시글이 고정됐다 — 브로드캐스트에는 댓글이 없어서(서버 postDto) 그대로
      // 넣으면 댓글 0개로 보이므로, 고정 목록을 댓글까지 통째로 다시 받는다.
      if (edited.isPost && edited.isPinned && pinnedPostsLoaded) {
        unawaited(loadPinnedPosts());
      }
      return;
    }
    for (final m in targets) {
      m.text = edited.text;
      m.textFormat = edited.textFormat;
      m.mentions = edited.mentions;
      m.editedAt = edited.editedAt;
      m.title = edited.title;
      m.pinnedAt = edited.pinnedAt;
      m.categoryId = edited.categoryId;
      m.mustReadAt = edited.mustReadAt;
      // 봇 메시지의 블록(단추를 누른 뒤 "승인됨"으로 바뀌는 등 — bot_blocks_view.dart).
      m.blocks = edited.blocks;
      // 사진·파일 메시지의 첨부 삭제 — 글 메시지끼리의 수정(비밀 대화 포함)에서는 파일 칸을 건드리지 않는다
      // (비밀 대화는 복호화한 파일 이름 등을 제자리에 덮어쓰고 있어서 서버 값으로 되돌리면 안 된다).
      if (m.type != MessageType.text || edited.type != MessageType.text) {
        m.type = edited.type;
        m.fileUrl = edited.fileUrl;
        m.fileName = edited.fileName;
        m.fileSize = edited.fileSize;
        m.mimeType = edited.mimeType;
        m.thumbnailUrl = edited.thumbnailUrl;
        m.attachments = edited.attachments;
      } else if (edited.isPost || edited.isPoll) {
        // 게시글·투표에 붙은 파일을 지웠을 때(파일 삭제) — 글 수정에서는 첨부가 안 바뀌고 그대로 내려온다.
        m.attachments = edited.attachments;
      }
    }
    if (edited.isPost) {
      _syncPinned(targets.first);
      _syncUnreadMustRead(targets.first);
    }
    notifyListeners();
  }

  /// [post]의 필독·읽음에 맞춰 "필독 안 읽음"을 고친다(받아 둔 적 있을 때만).
  void _syncUnreadMustRead(Message post) {
    final list = unreadMustRead;
    if (list == null) return;
    final mine = post.senderId != null && post.senderId == _session.userId;
    final should =
        post.isMustRead && !post.deleted && !mine && post.readByMe != true;
    final idx = list.indexWhere((e) => e.id == post.id);
    if (should && idx == -1) {
      unreadMustRead = [(id: post.id, title: post.title ?? ''), ...list];
    } else if (!should && idx != -1) {
      unreadMustRead = [...list]..removeAt(idx);
    } else if (should && list[idx].title != (post.title ?? '')) {
      unreadMustRead = [...list]
        ..[idx] = (id: post.id, title: post.title ?? '');
    }
  }

  /// 보드 위 "필독 안 읽음"을 서버에서 다시 받는다(보드를 열 때·재연결 뒤). 실패하면 이전 목록 그대로.
  Future<void> loadUnreadMustRead() async {
    try {
      final list = await _session.api!.fetchUnreadMustRead(room.id);
      if (_disposed) return;
      unreadMustRead = list;
      notifyListeners();
    } catch (_) {
      // 보드 위 부가 정보라 실패해도 조용히 넘어간다(다음에 열 때 다시).
    }
  }

  /// 보드 게시글을 열었다 — 바로 읽음으로 바꾸고(카드의 안 읽음 표시·"필독 안 읽음"에서 빠진다) 서버에 남긴다.
  /// 서버에 닿지 않아도 화면은 읽음으로 둔다(다음 목록에서 서버 값으로 맞춰진다).
  void markPostRead(Message post) {
    if (!post.isPost || post.deleted || !room.isBoard) return;
    final mine = post.senderId != null && post.senderId == _session.userId;
    final wasUnread = post.readByMe != true;
    final listed = unreadMustRead?.any((e) => e.id == post.id) ?? false;
    post.readByMe = true;
    for (final m in _instancesOf(post.id)) {
      m.readByMe = true;
    }
    if (listed) {
      unreadMustRead = [
        for (final e in unreadMustRead!)
          if (e.id != post.id) e,
      ];
    }
    if (wasUnread || listed) notifyListeners();
    // 쓴 사람은 늘 읽음이라 남길 게 없다. 다른 기기에서 이미 읽었어도 서버가 처음 시각만 남긴다.
    if (!mine) {
      unawaited(_session.api!.markPostRead(post.id).catchError((_) {}));
    }
  }

  /// Session이 post:read(누가 이 방 게시글을 처음 읽음)를 라우팅할 때 — 내 다른 기기에서 읽었으면 여기서도 읽음으로.
  void applyPostRead(String messageId, String userId) {
    if (userId == _session.userId) {
      final targets = _instancesOf(messageId);
      final listed = unreadMustRead?.any((e) => e.id == messageId) ?? false;
      if (targets.any((m) => m.readByMe != true) || listed) {
        for (final m in targets) {
          m.readByMe = true;
        }
        if (listed) {
          unreadMustRead = [
            for (final e in unreadMustRead!)
              if (e.id != messageId) e,
          ];
        }
        notifyListeners();
      }
    }
    if (!_postReads.isClosed) _postReads.add(messageId);
  }

  /// 게시글 필독 지정/해제(토픽을 관리할 수 있는 사람만). 응답을 곧바로 목록에 반영한다.
  Future<Message> setPostMustRead(String messageId, bool mustRead) async {
    final updated = await _session.api!.setPostMustRead(messageId, mustRead);
    applyEdit(updated);
    return updated;
  }

  /// 같은 id의 인스턴스들 — 타임라인([messages])의 것과, 아직 로드되지 않은 옛 게시글이라
  /// [pinnedPosts]에만 있는 것(대개는 둘이 같은 인스턴스 하나).
  List<Message> _instancesOf(String messageId) {
    final found = <Message>[];
    for (final m in messages) {
      if (m.id == messageId) {
        found.add(m);
        break;
      }
    }
    for (final p in pinnedPosts) {
      if (p.id == messageId && !found.any((f) => identical(f, p))) {
        found.add(p);
        break;
      }
    }
    return found;
  }

  /// REST로 다시 받은 게시글 값([incoming])을 [existing]에 옮긴다 — 바뀐 게 있으면 true.
  bool _syncPostState(Message existing, Message incoming) {
    if (existing.title == incoming.title &&
        existing.text == incoming.text &&
        existing.editedAt == incoming.editedAt &&
        existing.pinnedAt == incoming.pinnedAt &&
        existing.categoryId == incoming.categoryId &&
        existing.mustReadAt == incoming.mustReadAt &&
        (incoming.readByMe == null || existing.readByMe == incoming.readByMe) &&
        existing.deleted == incoming.deleted) {
      return false;
    }
    existing.title = incoming.title;
    existing.text = incoming.text;
    existing.textFormat = incoming.textFormat;
    existing.mentions = incoming.mentions;
    existing.editedAt = incoming.editedAt;
    existing.pinnedAt = incoming.pinnedAt;
    existing.categoryId = incoming.categoryId;
    existing.mustReadAt = incoming.mustReadAt;
    // 고정 목록 응답처럼 읽음을 모르는 값으로는 덮지 않는다.
    existing.readByMe = incoming.readByMe ?? existing.readByMe;
    existing.deleted = incoming.deleted;
    return true;
  }

  /// 타임라인 밖에서 들고 있던 게시글([post])의 댓글을 서버가 다시 준 목록([fresh])으로 맞춘다 —
  /// 새 댓글은 붙이고, 이미 있는 댓글은 끊긴 동안 놓친 수정·삭제를 따라간다.
  void _mergeComments(Message post, List<Comment> fresh) {
    final known = {for (final c in post.comments) c.id: c};
    var added = false;
    for (final c in fresh) {
      final existing = known[c.id];
      if (existing == null) {
        post.comments.add(c);
        added = true;
        continue;
      }
      existing.text = c.text;
      existing.textFormat = c.textFormat;
      existing.mentions = c.mentions;
      existing.editedAt = c.editedAt;
      existing.deleted = c.deleted;
    }
    if (added) post.comments.sort((a, b) => a.createdAt.compareTo(b.createdAt));
  }

  /// [post]의 고정 상태에 맞춰 [pinnedPosts]를 고친다 — 아직 한 번도 안 받아왔으면 그대로 둔다
  /// (보드가 열릴 때 loadPinnedPosts로 통째로 받는다). 목록이 바뀌면 true.
  bool _syncPinned(Message post) {
    if (!pinnedPostsLoaded) return false;
    final idx = pinnedPosts.indexWhere((p) => p.id == post.id);
    final shouldPin = post.isPinned && !post.deleted;
    if (shouldPin && idx == -1) {
      pinnedPosts.add(post);
      _sortPinnedPosts();
      return true;
    }
    if (!shouldPin && idx != -1) {
      pinnedPosts.removeAt(idx);
      return true;
    }
    return false;
  }

  void _sortPinnedPosts() =>
      pinnedPosts.sort((a, b) => b.createdAt.compareTo(a.createdAt));

  /// 보드 상단 "고정된 게시글"을 서버에서 다시 받아온다(보드를 열 때·재연결 뒤). 실패해도
  /// 보드 자체는 보여야 하므로 조용히 넘어가고 이전 목록을 그대로 둔다.
  Future<void> loadPinnedPosts() async {
    try {
      final list = await _session.api!.fetchPinnedPosts(room.id);
      if (_disposed) return;
      final byId = {for (final m in messages) m.id: m};
      final previous = {for (final p in pinnedPosts) p.id: p};
      pinnedPosts
        ..clear()
        ..addAll(
          list.map((p) {
            // 이미 타임라인에 있는 게시글이면 그 인스턴스를 같이 써서 댓글·수정이 한 곳에서 반영되게 한다.
            final inTimeline = byId[p.id];
            if (inTimeline != null) {
              _syncPostState(inTimeline, p);
              return inTimeline;
            }
            // 고정 목록에만 있던 옛 게시글도 원래 인스턴스를 그대로 쓴다(상세가 들고 있을 수 있다).
            final held = previous[p.id];
            if (held == null) return p;
            _syncPostState(held, p);
            _mergeComments(held, p.comments);
            return held;
          }),
        );
      _sortPinnedPosts();
      pinnedPostsLoaded = true;
      notifyListeners();
    } catch (_) {
      // 고정 목록은 보드 상단의 부가 정보라 실패해도 조용히 넘어간다(다음에 다시 열면 재시도).
    }
  }

  /// Session이 message:linkPreview 브로드캐스트를 라우팅할 때 호출한다.
  void applyLinkPreview(Message updated) {
    final idx = messages.indexWhere((m) => m.id == updated.id);
    if (idx == -1) return;
    messages[idx].linkPreview = updated.linkPreview;
    notifyListeners();
  }

  /// REST로 다시 받은 투표 메시지([incoming])의 값을 [existing]에 옮긴다 — 바뀐 게 있으면 true.
  bool _syncPollState(Message existing, Message incoming) {
    var changed = false;
    if (existing.deleted != incoming.deleted) {
      existing.deleted = incoming.deleted;
      changed = true;
    }
    final fresh = incoming.poll;
    final current = existing.poll;
    if (fresh == null) {
      if (current != null && incoming.deleted) {
        existing.poll = null;
        changed = true;
      }
    } else if (current == null || !current.sameContentAs(fresh)) {
      existing.poll = fresh;
      changed = true;
    }
    return changed;
  }

  /// 공감(이모지 반응)이 바뀌었을 때(message:reactions, 또는 내가 누른 직후 서버 답을 기다리지 않고) — 그 메시지(고정 게시글
  /// 목록에 같이 있으면 그것도)의 공감을 바꾼다. 아직 안 불러온 메시지면 아무것도 안 한다(나중에 받을 때 최신이 온다).
  void applyReactions(String messageId, List<MessageReaction> reactions) {
    final targets = _instancesOf(messageId);
    if (targets.isEmpty) return;
    for (final m in targets) {
      m.reactions = reactions;
    }
    notifyListeners();
  }

  /// 화상회의 기록 카드가 바뀌었을 때(call:card) — 그 메시지의 카드를 바꾼다. 목록에 없으면 false.
  bool applyCallCard(String messageId, CallCard card) {
    for (final m in messages) {
      if (m.id != messageId) continue;
      m.callCard = card;
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 투표가 들어 있는 메시지 — 메시지 id로 먼저, 없으면 투표 id로 찾는다(아직 못 받은 방이면 null).
  Message? _pollMessage({String? messageId, required String pollId}) {
    for (final m in messages) {
      if (!m.isPoll) continue;
      if ((messageId != null && m.id == messageId) || m.poll?.id == pollId) {
        return m;
      }
    }
    return null;
  }

  /// Session이 poll:updated(누가 투표했거나 마감됐다)를 라우팅할 때 호출한다 — 규약의 받는 쪽
  /// 규칙대로 [Poll.applyUpdate]가 내 선택·즐겨찾기를 지킨다. 목록에 없으면 false.
  bool applyPollUpdate(PollUpdatedEvent event, {String? myUserId}) {
    final m = _pollMessage(messageId: event.messageId, pollId: event.pollId);
    if (m == null || m.deleted) return false;
    m.poll = Poll.applyUpdate(
      m.poll,
      event.poll,
      actorId: event.actorId,
      actorOptionIds: event.actorOptionIds,
      myUserId: myUserId,
    );
    notifyListeners();
    return true;
  }

  /// 내가 투표/마감 요청을 보내고 받은 응답(내 기준 poll)을 곧바로 반영한다 — 소켓 이벤트를
  /// 기다리지 않아도 카드가 바뀐다(같은 이벤트가 나중에 와도 결과는 같다).
  bool applyPollResult(Poll poll) {
    final m = _pollMessage(pollId: poll.id);
    if (m == null || m.deleted) return false;
    m.poll = poll;
    notifyListeners();
    return true;
  }

  /// 내 즐겨찾기 표시가 바뀌었다(내 다른 기기 포함).
  bool applyPollFavorite(String messageId, String pollId, bool favorite) {
    final m = _pollMessage(messageId: messageId, pollId: pollId);
    final poll = m?.poll;
    if (m == null || poll == null || poll.favorite == favorite) return false;
    m.poll = poll.copyWith(favorite: favorite);
    notifyListeners();
    return true;
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
  /// 표시만 바뀌어야 하기 때문이다. 비밀 대화 평문 캐시는 Session이 지운다(이 방 화면이 없어도).
  void applyDelete(String messageId) {
    final targets = _instancesOf(messageId);
    if (targets.isEmpty) return;
    for (final m in targets) {
      m.deleted = true;
    }
    // 지워진 게시글은 고정 목록에서도 빠진다(서버 pinned-posts도 삭제된 글은 안 준다).
    pinnedPosts.removeWhere((p) => p.id == messageId);
    notifyListeners();
  }

  /// Session이 message:expired(비밀 대화 자동 삭제 타이머 만료)를 라우팅할 때 호출한다.
  /// 소프트 삭제(applyDelete)와 달리 흔적 없이 없어지는 게 취지라 리스트에서 완전히 뺀다 —
  /// 서버가 FK cascade로 댓글도 같이 지웠으므로 그 댓글의 합성 타임라인 항목도 함께 제거한다.
  /// 그 알림을 놓쳤을 때도 같은 일을 한다(이 기기에서 삭제 예정 시각이 지나 지웠거나, 다시 받은
  /// 히스토리에 없음 — Session._handleExpiredSecretTexts, [_reconcileSecretPage]). 평문 캐시는 Session·
  /// SecretKeyStore가 이 방 화면과 상관없이 지운다.
  void applyExpire(String messageId) {
    var removed = false;
    for (final m in messages) {
      if (m.id == messageId ||
          (m.type == MessageType.comment &&
              m.asComment?.messageId == messageId)) {
        removed = true;
        break;
      }
    }
    // 아무도 안 읽은 게시글을 지우면 서버가 이 경로(완전 삭제)로 알린다 — 고정 목록에서도 빼고,
    // 게시글 상세처럼 그 인스턴스를 들고 있는 화면은 "삭제된 게시글"로 바뀌게 표시해 둔다.
    final posts = [
      for (final m in _instancesOf(messageId))
        if (m.isPost) m,
    ];
    for (final p in posts) {
      p.deleted = true;
    }
    pinnedPosts.removeWhere((p) => p.id == messageId);
    messages.removeWhere(
      (m) =>
          m.id == messageId ||
          (m.type == MessageType.comment &&
              m.asComment?.messageId == messageId),
    );
    if (removed || posts.isNotEmpty) notifyListeners();
  }

  /// 연결이 끊겼다가 다시 붙었을 때 Session이 호출한다. 끊긴 동안 놓쳤을 수 있는 메시지/댓글을
  /// 다시 받아와 합친다(보드의 고정 목록을 받아둔 적 있으면 그것도 다시 받는다).
  Future<void> refresh() async {
    if (pinnedPostsLoaded) unawaited(loadPinnedPosts());
    if (unreadMustRead != null) unawaited(loadUnreadMustRead());
    try {
      final generation = _secretCacheGeneration;
      final history = await _session.api!.fetchRoomMessages(
        room.id,
        limit: _pageSize,
      );
      await _session.decryptHistory(room, history);
      // 비밀 대화: 끊긴 동안 서버가 자동 삭제·삭제한 메시지는 그 알림이 다시 오지 않는다 — 이 응답으로 맞춘다.
      await _reconcileSecretPage(
        history,
        before: null,
        limit: _pageSize,
        sinceGeneration: generation,
      );
      // 처음 불러오기가 실패했던 방이면, 이번에 받은 최근 페이지로 과거 페이지 커서를 잡고 오류를
      // 거둔다 — 안 그러면 목록은 보여도 위(보드는 아래)로 더 불러오기가 영영 안 된다.
      final recovering = error != null || fromCache;
      if (recovering) {
        error = null;
        fromCache = false;
        // 이 기기 DB로 위까지 넘겨 봤으면 그 커서를 그대로 이어 쓴다(서버에서 그보다 오래된 것을 받는다).
        if (_historyCursor == null) {
          _advanceHistoryCursor(history);
          if (history.where((m) => !m.outOfWindow).length < _pageSize) {
            hasMoreHistory = false;
          }
        }
      }
      if (!_mergeHistory(history) && !recovering) return;
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
        final generation = _secretCacheGeneration;
        final history = await _session.api!.fetchRoomMessages(
          room.id,
          limit: pageSize,
          before: cursor,
        );
        await _session.decryptHistory(room, history);
        await _reconcileSecretPage(
          history,
          before: cursor,
          limit: pageSize,
          sinceGeneration: generation,
        );
        if (history.isEmpty) break;
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
        final generation = _secretCacheGeneration;
        final history = await _session.api!.fetchRoomMessages(
          room.id,
          limit: pageSize,
          before: cursor,
        );
        await _session.decryptHistory(room, history);
        await _reconcileSecretPage(
          history,
          before: cursor,
          limit: pageSize,
          sinceGeneration: generation,
        );
        if (history.isEmpty) break;
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
    final selfDestruct = room.secretSelfDestructSeconds;
    final manager = _session.secretSessionManager;
    // 끊겨 있으면 읽음 신호는 소켓에 쌓였다가 다시 붙을 때 서버에 닿고, 서버의 자동 삭제 카운트도 그때 시작한다 —
    // 지금 시각으로 어림하면 서버보다 일찍 지우게 되므로, 붙어 있을 때만 어림한다(끊겨 있으면 서버 값을 기다린다).
    final signalLive = _session.secretReadSignalLive;
    for (final m in messages) {
      if (m.senderId == _session.userId) continue;
      // 이 기기에서 풀지 못한 메시지는 읽었다고 알리지 않는다 — 자동 삭제 타이머가 그때부터 돌아, 이 대화를 맺은 기기가
      // 읽기도 전에(또는 늦게 와 아직 못 푼 메시지가) 서버에서 지워진다.
      if (m.decryptFailed) continue;
      if (m.type != MessageType.text &&
          m.type != MessageType.image &&
          m.type != MessageType.file) {
        continue;
      }
      _session.chatSocket.markSecretMessageRead(room.id, m.id);
      // 타이머가 켜진 방이면 서버는 지금부터 그만큼 뒤에 이 메시지를 지운다. 그 확정 알림
      // (secret:message-read)을 끊겨서 못 받아도 이 기기에 평문이 남지 않게, 이 기기 기준 예정
      // 시각을 먼저 캐시에 적어 둔다(서버가 아직 읽음을 확정해 주지 않은 메시지만 — 서버 값이 오면 그걸로 바뀐다).
      if (selfDestruct != null &&
          m.readAt == null &&
          manager != null &&
          signalLive) {
        unawaited(manager.noteLocalRead(m.id, Duration(seconds: selfDestruct)));
      }
    }
  }

  /// [format]은 [text]의 글자 서식 — [text]는 이미 앞뒤 공백을 뗀 것이어야 위치가 맞는다
  /// (RichTextEditingController.formatted). 비밀 대화는 서식 없이 보낸다.
  ///
  /// 비밀 대화가 아니면 보내기 대기열(message_outbox.dart)에 넣고 바로 돌아온다 — 연결이 끊겨 있으면 붙을 때 보내고, 서버가 거절하면
  /// 대화방 아래 대기 말풍선에 실패로 남는다(입력한 글을 잃지 않는다). 비밀 대화는 예전처럼 보내고 실패하면 던진다.
  Future<void> sendText(
    String text, {
    List<TextFormatRun>? format,
    List<Mention>? mentions,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (!room.isSecret) {
      final sameText = trimmed == text;
      final formatJson = sameText ? textFormatToJson(format) : null;
      final mentionsJson = sameText ? mentionsToJson(mentions) : null;
      _session.outbox.submit(
        roomId: room.id,
        payload: {
          'type': 'text',
          'text': trimmed,
          'textFormat': ?formatJson,
          'mentions': ?mentionsJson,
        },
      );
      return;
    }
    // 비밀 대화 — 평문으로 대기열에 넣고(메모리에만 — 이 기기에 저장하지 않는다) 보낼 때마다 그때의 암호화 상태로 암호화한다
    // (Session._deliverOutbox). 연결이 없으면 붙을 때 보낸다.
    _session.outbox.submit(
      roomId: room.id,
      payload: {'type': 'text', 'text': trimmed},
      secret: true,
    );
  }

  /// 이모티콘 전송 — text 필드에 스티커 id만 실어 보낸다(client/lib/data/stickers.dart 참고).
  /// 파일 업로드가 없어서 sendText와 거의 동일하고, type만 다르다.
  Future<void> sendSticker(String stickerId) async {
    if (!room.isSecret) {
      _session.outbox.submit(
        roomId: room.id,
        payload: {'type': 'sticker', 'text': stickerId},
      );
      return;
    }
    _session.outbox.submit(
      roomId: room.id,
      payload: {'type': 'sticker', 'text': stickerId},
      secret: true,
    );
  }

  /// 첨부 일부를 아직 올리지 못한 채 보낸다(연결이 끊겨 올리지 못함 — chat_input_bar.dart) — 올린 것([uploaded])은 그대로, 올리지
  /// 못한 것([pending] — 바이트)은 이 기기 앱 폴더(웹은 IndexedDB)에 복사해 보내기 대기열에 넣고, 연결되면 올려서 한 메시지로 보낸다
  /// (Session._deliverOutbox). 사진만이면 사진 격자, 파일이 섞이면 파일 목록. 비밀 대화는 [_queueSecretAttachments]. 담지 못하면
  /// false(부르는 쪽이 알린다).
  Future<bool> queueAttachmentMessage({
    required List<UploadedAttachment> uploaded,
    required List<
      ({List<int> bytes, String name, String? mimeType, bool isImage})
    >
    pending,
    String? caption,
    List<TextFormatRun>? captionFormat,
    List<Mention>? captionMentions,
  }) async {
    if (room.isSecret) {
      await _queueSecretAttachments(uploaded, pending, caption: caption);
      return true;
    }
    final clientId = newClientId();
    final files = await _session.stashOutboxFiles(clientId, pending);
    if (files == null) return false;
    final trimmed = caption?.trim();
    final captionText = trimmed?.isNotEmpty == true ? trimmed : null;
    final formatJson = trimmed == caption
        ? textFormatToJson(captionFormat)
        : null;
    final mentionsJson = trimmed == caption
        ? mentionsToJson(captionMentions)
        : null;
    final allImages =
        uploaded.every((u) => u.isImage) && pending.every((p) => p.isImage);
    _session.outbox.submit(
      roomId: room.id,
      clientId: clientId,
      payload: {
        'type': allImages ? 'image' : 'file',
        'text': ?captionText,
        'textFormat': ?formatJson,
        'mentions': ?mentionsJson,
        'attachments': [for (final u in uploaded) u.toPayload()],
      },
      files: files,
    );
    return true;
  }

  /// 비밀 대화의 첨부를 대기열로 — 첨부마다 봉투가 하나라 한 장씩 따로 보낸다(sendUploadedAttachments와 같다 — 설명은 첫 장에).
  /// 올린 것은 그대로 보내고, 못 올린 것은 평문 바이트를 **메모리에만** 든 채 넣어(디스크에 남기지 않는다 — 앱을 끄면 사라짐)
  /// 연결되면 암호화해 올려서 보낸다(Session._deliverOutbox).
  Future<void> _queueSecretAttachments(
    List<UploadedAttachment> uploaded,
    List<({List<int> bytes, String name, String? mimeType, bool isImage})>
    pending, {
    String? caption,
  }) async {
    String? captionLeft = caption?.trim();
    if (captionLeft?.isEmpty == true) captionLeft = null;
    for (final u in uploaded) {
      await sendUploadedAttachment(u, caption: captionLeft);
      captionLeft = null;
    }
    for (final p in pending) {
      _session.outbox.submit(
        roomId: room.id,
        payload: {'type': p.isImage ? 'image' : 'file', 'text': ?captionLeft},
        files: [
          OutboxFile(
            path: '',
            name: p.name,
            size: p.bytes.length,
            mimeType: p.mimeType,
            isImage: p.isImage,
            bytes: p.bytes is Uint8List
                ? p.bytes as Uint8List
                : Uint8List.fromList(p.bytes),
          ),
        ],
        secret: true,
      );
      captionLeft = null;
    }
  }

  /// 보드 뷰 게시글을 올린다 — 채팅 메시지와 같은 message:send 경로에 type 'post'와 제목을
  /// 실어 보낸다. [attachments]는 이미 올라간 첨부(uploadLocalFiles/uploadAttachment 결과)이고,
  /// [textFormat]은 [text](앞뒤 공백을 뗀 것)의 글자 서식이다. 보드 목록 반영은 다른 메시지처럼
  /// 서버가 돌려보내는 message:new로 이뤄지고, 여기선 서버가 저장한 게시글(있으면)을 돌려준다.
  /// 읽기 전용/보관된 토픽 등 서버가 거절하면 그 문구로 [MessageSendException]이 난다.
  Future<Message?> sendPost({
    required String title,
    required String text,
    List<TextFormatRun>? textFormat,
    List<Mention>? mentions,
    List<UploadedAttachment> attachments = const [],
    String? categoryId,
    bool mustRead = false,
  }) async {
    final trimmedTitle = title.trim();
    final trimmedText = text.trim();
    _validatePost(trimmedTitle, trimmedText);
    if (attachments.length > postAttachmentsMaxCount) {
      throw ApiException(tr('첨부는 30개까지 올릴 수 있습니다.'));
    }
    return _session.chatSocket.send(
      roomId: room.id,
      type: 'post',
      title: trimmedTitle,
      categoryId: categoryId,
      mustRead: mustRead,
      text: trimmedText,
      textFormat: trimmedText == text ? textFormat : null,
      mentions: trimmedText == text ? mentions : null,
      attachments: attachments.isEmpty
          ? null
          : [for (final u in attachments) u.toPayload()],
    );
  }

  /// 게시글 제목·본문을 고친다(작성자만, 첨부는 그대로). 응답으로 받은 게시글을 곧바로 목록에
  /// 반영하고(다른 멤버에겐 message:edited로 퍼진다) 돌려준다.
  Future<Message> editPost(
    String messageId, {
    required String title,
    required String text,
    List<TextFormatRun>? textFormat,
    List<Mention>? mentions,
    bool setCategory = false,
    String? categoryId,
  }) async {
    final trimmedTitle = title.trim();
    final trimmedText = text.trim();
    _validatePost(trimmedTitle, trimmedText);
    final updated = await _session.api!.editPost(
      messageId,
      title: trimmedTitle,
      text: trimmedText,
      textFormat: trimmedText == text ? textFormat : null,
      mentions: trimmedText == text ? mentions : const [],
      setCategory: setCategory,
      categoryId: categoryId,
    );
    applyEdit(updated);
    return updated;
  }

  /// 게시글 고정/해제(토픽을 관리할 수 있는 사람만). 응답을 곧바로 목록·고정 목록에 반영한다.
  Future<Message> setPostPinned(String messageId, bool pinned) async {
    final updated = await _session.api!.setPostPinned(messageId, pinned);
    applyEdit(updated);
    return updated;
  }

  /// 서버와 같은 규칙(글자 수는 postTextLength 단위)으로 먼저 걸러서, 보내기 전에 편집 화면에 바로
  /// 알려줄 수 있게 한다.
  void _validatePost(String title, String text) {
    if (title.isEmpty) throw ApiException(tr('제목을 입력하세요.'));
    if (postTextLength(title) > postTitleMaxLength) {
      throw ApiException(tr('제목은 100자까지 쓸 수 있습니다.'));
    }
    if (text.isEmpty) throw ApiException(tr('내용을 입력하세요.'));
    if (postTextLength(text) > postTextMaxLength) {
      throw ApiException(tr('내용은 20000자까지 쓸 수 있습니다.'));
    }
  }

  /// 파일을 서버에 올린다(썸네일 업로드, 비밀 대화면 원본 암호화까지 포함) — 실제 메시지/댓글
  /// 전송(sendUploadedAttachment/postUploadedCommentAttachment)과 분리해서, 첨부한 즉시(보내기를
  /// 누르기 전부터) 입력창에서 업로드를 시작할 수 있게 한다. [originalBytes]/[thumbBytes]는
  /// 호출부(ChatInputBar/CommentInputBar)가 첨부 즉시 한 번만 읽어/생성해서 넘긴다 — 여기서
  /// 다시 읽거나 다시 생성하지 않는다(큰 파일을 두 번 읽지 않기 위함). [onProgress]/
  /// [cancelToken]은 원본 파일 업로드에만 연결한다(썸네일은 작고 빨라서 진행률/취소를 안 건다).
  Future<UploadedAttachment> uploadAttachment(
    XFile file, {
    required bool isImage,
    required Uint8List originalBytes,
    required Uint8List? thumbBytes,
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    // 평문 방은 방과 무관한 업로드(예약 메시지 첨부 등)와 같은 코드로 올린다.
    if (!room.isSecret) {
      return _uploadPlainAttachment(
        _session.api!,
        file,
        isImage: isImage,
        thumbBytes: thumbBytes,
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
    }

    return uploadSecretBytes(
      _session.api!,
      originalBytes,
      isImage: isImage,
      name: file.name,
      mimeType: file.mimeType,
      thumbBytes: thumbBytes,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// 로컬 파일 하나를 채팅 입력칸과 같은 방식으로 올린다 — 이미지면(안 주면 확장자로 판별)
  /// 버블/카드 미리보기용 썸네일도 만들어 같이 올린다. 게시글 편집 화면처럼 입력칸 밖에서
  /// 첨부를 올릴 때 쓴다. 미리보기용 썸네일 바이트가 따로 필요하면 generateThumbnail을 쓰면 된다.
  Future<UploadedAttachment> uploadLocalFile(
    XFile file, {
    bool? isImage,
    void Function(int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) async {
    final image = isImage ?? looksLikeImagePath(file.name);
    // 원본을 메모리로 읽는 건 썸네일을 만들거나(이미지) 암호화할 때(비밀 대화)뿐 — 큰 일반
    // 파일은 읽지 않고 그대로 스트리밍해서 올린다(uploadAttachment는 비밀 대화에서만 바이트를 쓴다).
    var upload = file;
    var bytes = image || room.isSecret
        ? await file.readAsBytes()
        : Uint8List(0);
    // 휴대폰 데이터면 사진을 일반 화질로(photo_quality.dart — 게시글 편집·다른 앱에서 공유).
    if (image) {
      final reduced = await photoForUpload(_session.settings, file, bytes);
      if (reduced != null) {
        upload = reduced.file;
        bytes = reduced.bytes;
      }
    }
    final thumbBytes = image ? await generateThumbnail(bytes) : null;
    return uploadAttachment(
      upload,
      isImage: image,
      originalBytes: bytes,
      thumbBytes: thumbBytes,
      onProgress: onProgress,
      cancelToken: cancelToken,
    );
  }

  /// 여러 파일을 순서대로 올려 첨부 목록을 만든다(sendPost에 그대로 넘기면 된다). [onProgress]는
  /// 지금 올리는 파일의 순번(0부터)과 그 파일의 진행 바이트를 알려준다. 하나라도 실패하면
  /// 그 예외가 그대로 나간다(이미 올라간 앞 파일들은 서버에 남지만 어디에도 연결되지 않는다).
  Future<List<UploadedAttachment>> uploadLocalFiles(
    List<XFile> files, {
    void Function(int index, int sent, int total)? onProgress,
    UploadCancelToken? cancelToken,
  }) => _uploadInOrder(
    files,
    (file, progress) =>
        uploadLocalFile(file, onProgress: progress, cancelToken: cancelToken),
    onProgress: onProgress,
  );

  /// 이미 업로드가 끝난 첨부(uploadAttachment 결과)로 채팅 메시지를 보낸다. [caption]을 같이
  /// 주면(첨부 후 텍스트도 입력한 경우) 그 메시지 하나에 첨부와 텍스트가 함께 실린다. 비밀
  /// 대화면 파일 바이트 자체가 이미 암호화된 채로 올라가 있으므로(서버는 opaque한 바이트로만
  /// 취급), 캡션+원본 파일정보+복호화 키를 메시지 암호문 봉투 안에 함께 넣어 보낸다 — 비밀 대화의 글처럼 평문으로 대기열에
  /// 넣고(메모리에만) 보낼 때 봉투로 암호화한다(Session._deliverOutbox — 연결이 없으면 붙을 때).
  Future<void> sendUploadedAttachment(
    UploadedAttachment u, {
    String? caption,
    List<TextFormatRun>? captionFormat,
    List<Mention>? captionMentions,
  }) async {
    final trimmedCaption = caption?.trim();
    if (room.isSecret) {
      _session.outbox.submit(
        roomId: room.id,
        payload: {
          'type': u.isImage ? 'image' : 'file',
          'text': ?(trimmedCaption?.isNotEmpty == true ? trimmedCaption : null),
          'secretAttachment': secretAttachmentPayload(u),
        },
        secret: true,
      );
      return;
    }

    // 첨부는 이미 올라가 있어서 본문만 대기열로 보낸다(끊겨 있으면 붙을 때).
    final captionText = trimmedCaption?.isNotEmpty == true
        ? trimmedCaption
        : null;
    final formatJson = trimmedCaption == caption
        ? textFormatToJson(captionFormat)
        : null;
    final mentionsJson = trimmedCaption == caption
        ? mentionsToJson(captionMentions)
        : null;
    _session.outbox.submit(
      roomId: room.id,
      payload: {
        'type': u.isImage ? 'image' : 'file',
        'text': ?captionText,
        'textFormat': ?formatJson,
        'mentions': ?mentionsJson,
        'fileUrl': u.url,
        'fileName': u.fileName,
        'fileSize': u.size,
        'mimeType': ?u.mimeType,
        'thumbnailUrl': ?u.thumbnailUrl,
      },
    );
  }

  /// 이미 올라간 첨부 여러 개를 **한 메시지**로 보낸다(사진은 격자, 파일은 목록으로 보인다).
  /// 비밀 대화는 첨부마다 복호화 키가 따로라 봉투에 한 개만 담을 수 있어서, 거기서는
  /// 예전처럼 한 장씩 따로 보낸다(sendUploadedAttachment).
  Future<void> sendUploadedAttachments(
    List<UploadedAttachment> items, {
    String? caption,
    List<TextFormatRun>? captionFormat,
    List<Mention>? captionMentions,
  }) async {
    if (items.isEmpty) return;
    if (items.length == 1 || room.isSecret) {
      for (var i = 0; i < items.length; i++) {
        await sendUploadedAttachment(
          items[i],
          caption: i == 0 ? caption : null,
          captionFormat: i == 0 ? captionFormat : null,
          captionMentions: i == 0 ? captionMentions : null,
        );
      }
      return;
    }
    final trimmed = caption?.trim();
    final captionText = trimmed?.isNotEmpty == true ? trimmed : null;
    final formatJson = trimmed == caption
        ? textFormatToJson(captionFormat)
        : null;
    final mentionsJson = trimmed == caption
        ? mentionsToJson(captionMentions)
        : null;
    _session.outbox.submit(
      roomId: room.id,
      payload: {
        // 사진만 모였으면 격자(image), 하나라도 파일이면 파일 목록(file) 말풍선이 된다.
        'type': items.every((u) => u.isImage) ? 'image' : 'file',
        'text': ?captionText,
        'textFormat': ?formatJson,
        'mentions': ?mentionsJson,
        'attachments': [for (final u in items) u.toPayload()],
      },
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _readSub?.cancel();
    _postReads.close();
    TypingGate.instance.cancel(this);
    super.dispose();
  }
}
