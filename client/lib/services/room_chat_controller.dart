import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/message.dart';
import '../models/room.dart';
import 'session.dart';

/// 방 하나의 메시지 목록/전송을 담당하는 컨트롤러. 방을 열 때 Session이 생성해서 캐싱한다.
class RoomChatController extends ChangeNotifier {
  RoomChatController(this._session, this.room) : readBoundary = room.lastRead[_session.userId] ?? 0 {
    _readSub = _session.chatSocket.readEvents.where((e) => e.roomId == room.id).listen((_) => notifyListeners());
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
      messages
        ..clear()
        ..addAll(history);
    } catch (e) {
      error = e.toString();
    }
    loading = false;
    notifyListeners();
    markReadNow();
  }

  /// Session이 이 방으로 들어온 실시간 메시지를 라우팅할 때 호출한다.
  void feed(Message m) {
    messages.add(m);
    notifyListeners();
    // 지금 이 방을 실제로 보고 있을 때만 읽음 처리한다 (백그라운드/다른 방을 보는 중이면 안읽음으로 남겨야 함).
    if (_session.activeRoomId == room.id && _session.appInForeground) markReadNow();
  }

  /// 연결이 끊겼다가 다시 붙었을 때 Session이 호출한다. 끊긴 동안 놓쳤을 수 있는 메시지를
  /// 다시 받아와 이미 가진 것과 id로 비교해 새로 온 것만 합친다.
  Future<void> refresh() async {
    try {
      final history = await _session.api!.fetchRoomMessages(room.id);
      final existingIds = messages.map((m) => m.id).toSet();
      final newOnes = history.where((m) => !existingIds.contains(m.id));
      if (newOnes.isEmpty) return;
      messages
        ..addAll(newOnes)
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      notifyListeners();
      if (_session.activeRoomId == room.id && _session.appInForeground) markReadNow();
    } catch (_) {
      // 재연결 직후 갱신 실패는 조용히 넘어간다 — 다음 재연결 때 다시 시도됨.
    }
  }

  void markReadNow() => _session.chatSocket.markRead(room.id);

  Future<void> sendText(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return Future.value();
    return _session.chatSocket.send(roomId: room.id, type: 'text', text: trimmed);
  }

  /// [caption]을 같이 주면(이미지/파일 첨부 후 메시지를 입력하고 보낸 경우) 그 메시지 하나에
  /// 텍스트와 첨부가 함께 실린다.
  Future<void> sendFile(File file, {required bool isImage, String? caption}) async {
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
