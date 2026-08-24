import 'dart:async';

import 'package:socket_io_client/socket_io_client.dart' as socket_io;

import '../models/message.dart';
import '../models/room.dart';
import 'pinned_tls.dart';

/// room:read 브로드캐스트 한 건. 누가(userId) 언제(lastReadAt) 어느 방(roomId)을 읽었는지.
class RoomReadEvent {
  final String roomId;
  final String userId;
  final int lastReadAt;
  const RoomReadEvent({required this.roomId, required this.userId, required this.lastReadAt});

  factory RoomReadEvent.fromJson(Map<String, dynamic> json) => RoomReadEvent(
        roomId: json['roomId'] as String,
        userId: json['userId'] as String,
        lastReadAt: (json['lastReadAt'] as num).toInt(),
      );
}

/// Socket.io 연결을 감싸서 Message/Room/읽음 이벤트 스트림으로 노출합니다.
class ChatSocket {
  socket_io.Socket? _socket;
  final _messageController = StreamController<Message>.broadcast();
  final _roomController = StreamController<Room>.broadcast();
  final _readController = StreamController<RoomReadEvent>.broadcast();
  final _reconnectController = StreamController<void>.broadcast();
  final _authErrorController = StreamController<void>.broadcast();

  Stream<Message> get messages => _messageController.stream;

  /// 서버가 방 생성/합류를 알려줄 때(room:created) 흘러나온다. Session이 방 목록을 upsert하는 데 쓴다.
  Stream<Room> get roomEvents => _roomController.stream;

  /// 누군가 방을 읽었다는 브로드캐스트. 안읽음 카운터 갱신에 쓴다.
  Stream<RoomReadEvent> get readEvents => _readController.stream;

  /// 연결이 끊겼다가 다시 붙었을 때(최초 연결 제외) 흘러나온다.
  /// 끊긴 동안 놓친 메시지/방 상태를 다시 받아오는 용도.
  Stream<void> get reconnected => _reconnectController.stream;

  /// 서버가 handshake에서 인증을 거부했을 때(만료됐거나 비밀번호 변경 등으로 폐기된
  /// accessToken으로 연결을 시도한 경우) 흘러나온다. Session이 새 accessToken을 받아
  /// 다시 연결을 시도하는 데 쓴다.
  Stream<void> get authErrors => _authErrorController.stream;
  bool get isConnected => _socket?.connected ?? false;

  bool _looksLikeAuthError(dynamic err) {
    final message = err is Map ? err['message']?.toString() : err?.toString();
    return message?.toLowerCase().contains('unauthorized') ?? false;
  }

  Future<void> connect({required String baseUrl, required String token}) async {
    _socket?.dispose();

    // 서버가 자체 서명 인증서를 쓰므로, 앱에 내장해둔 그 인증서만 신뢰하는 커넥터로
    // WebSocket을 연결한다(REST 쪽 PinnedTls.httpClient()와 같은 목적).
    final connector = await PinnedTls.webSocketConnector();

    final socket = socket_io.io(
      baseUrl,
      socket_io.OptionBuilder()
          .setTransports(['websocket'])
          .setAuth({'token': token})
          .setWebSocketConnector(connector)
          .disableAutoConnect()
          // socket_io_client가 같은 baseUrl에 대해 내부적으로 Manager를 전역 캐싱하는데,
          // 재로그인처럼 같은 앱 프로세스 안에서 connect()를 다시 호출하는 경우 이 캐시가
          // 이전 계정(토큰)으로 인증된 연결을 재사용해버릴 수 있다 — 그러면 겉보기엔 새
          // 토큰으로 연결한 것 같아도 서버는 예전 사용자로 인식한다. forceNew로 매번
          // 완전히 새 연결을 강제해서 이 문제를 원천 차단한다.
          .enableForceNew()
          .build(),
    );

    socket.on('message:new', (data) {
      _messageController.add(Message.fromJson(Map<String, dynamic>.from(data as Map)));
    });
    socket.on('room:created', (data) {
      _roomController.add(Room.fromJson(Map<String, dynamic>.from(data as Map)));
    });
    socket.on('room:read', (data) {
      _readController.add(RoomReadEvent.fromJson(Map<String, dynamic>.from(data as Map)));
    });
    socket.onReconnect((_) => _reconnectController.add(null));
    socket.onConnectError((err) {
      if (_looksLikeAuthError(err)) _authErrorController.add(null);
    });
    socket.onReconnectError((err) {
      if (_looksLikeAuthError(err)) _authErrorController.add(null);
    });

    socket.connect();
    _socket = socket;
  }

  /// 메시지를 보내고 서버의 ack(message:send 응답)를 기다린다.
  /// 서버가 실패를 응답하거나 일정 시간 내 응답이 없으면 예외를 던진다.
  /// (연결이 끊긴 상태라면 socket.io가 알아서 큐에 담아뒀다가 재연결 시 보내므로,
  /// 짧은 연결 끊김 정도는 타임아웃 전에 ack가 도착해 정상 처리된다.)
  Future<void> send({
    required String roomId,
    required String type,
    String? text,
    String? fileUrl,
    String? fileName,
    int? fileSize,
    String? mimeType,
  }) {
    final socket = _socket;
    if (socket == null) {
      return Future.error(Exception('서버와 연결되어 있지 않습니다.'));
    }

    final completer = Completer<void>();
    socket.emitWithAck(
      'message:send',
      {
        'roomId': roomId,
        'type': type,
        'text': ?text,
        'fileUrl': ?fileUrl,
        'fileName': ?fileName,
        'fileSize': ?fileSize,
        'mimeType': ?mimeType,
      },
      ack: (dynamic response) {
        if (completer.isCompleted) return;
        final map = response is Map ? Map<String, dynamic>.from(response) : const <String, dynamic>{};
        if (map['ok'] == true) {
          completer.complete();
        } else {
          completer.completeError(Exception(map['error']?.toString() ?? '메시지 전송에 실패했습니다.'));
        }
      },
    );
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw Exception('서버 응답이 없습니다. 연결 상태를 확인해주세요.'),
    );
  }

  void markRead(String roomId) {
    _socket?.emit('room:read', {'roomId': roomId});
  }

  void dispose() {
    // 스트림 컨트롤러는 Session이 재로그인 시 같은 ChatSocket 인스턴스로 connect()를
    // 다시 호출할 수 있어 여기서 닫지 않는다(소켓 자체만 정리).
    _socket?.dispose();
    _socket = null;
  }
}
